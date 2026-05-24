# frozen_string_literal: true

module Phronomy
  # Singleton event loop that manages all FSMSession instances.
  #
  # A single background thread reads from a global {Phronomy::AsyncQueue} and
  # dispatches events to their target FSMSession.  IO work (LLM calls, tool
  # calls) runs in separate IO threads that post events back to the loop via
  # EventLoop#post.
  #
  # Activated with: +Phronomy.configure { |c| c.event_loop = true }+
  #
  # == Fork safety
  #
  # +EventLoop.instance+ is lazily initialized. The background thread is not
  # created until the first call, so Puma worker forking does not duplicate the
  # thread. No +after_fork+ hook is required.
  #
  # == Deadlock warning
  #
  # Do NOT call +Workflow#invoke+ (in EventLoop mode) from within a workflow
  # entry action. The entry action runs on the EventLoop thread; a nested
  # +invoke+ would block waiting for the same thread to process events →
  # deadlock. Use the async IO pattern instead (spawn a Thread, post events
  # back to the EventLoop).
  class EventLoop
    # Returns the singleton instance, creating and starting it on first call.
    def self.instance
      @instance ||= new.tap(&:start)
    end

    # Returns true when called from within the EventLoop dispatch task.
    # Uses a task-local key set by the Runtime-spawned dispatch task so that
    # the check works correctly for both thread-based and future fiber-based
    # scheduler backends.
    # @return [Boolean]
    # @api private
    def self.current?
      Phronomy::Task.current&.name == "event-loop"
    end

    # Stops and destroys the singleton. Primarily used in tests.
    # @api private
    def self.reset!
      @instance&.stop
      @instance = nil
    end

    def initialize
      @queue = Phronomy::AsyncQueue.new  # global event queue (thread-safe; no Mutex needed)
      @fsms = {}                  # { id => FSMSession }     — EventLoop thread only
      @waiting = {}               # { id => completion_queue } — EventLoop thread only
      # Mutex-backed FSM count for drain-mode shutdown.
      @fsm_count_mutex = Mutex.new
      @fsm_count_cond = ConditionVariable.new
      @fsm_count = 0
      # Token cancelled when shutdown is requested; new child sessions receive it.
      @shutdown_token = Phronomy::CancellationToken.new
      # Fairness metrics (EventLoop thread only, except where noted)
      @lag_mutex = Mutex.new
      @last_lag_ns = 0
      @max_lag_ns = 0
      @dispatch_count = 0
      @total_lag_ns = 0
    end

    # Returns the most recently measured event-loop lag in seconds.
    # Lag is the wall-clock time between {#post} and the moment the event
    # is dequeued for dispatch.  Thread-safe.
    # @return [Float]
    # @api private
    def last_lag_seconds
      @lag_mutex.synchronize { @last_lag_ns } / 1_000_000_000.0
    end

    # Returns the maximum event-loop lag seen since the loop was started.
    # Thread-safe.
    # @return [Float]
    # @api private
    def max_lag_seconds
      @lag_mutex.synchronize { @max_lag_ns } / 1_000_000_000.0
    end

    # Returns the mean event-loop lag across all dispatched events since the
    # loop was started.  Returns 0.0 when no events have been dispatched.
    # Thread-safe.
    # @return [Float]
    # @api private
    def average_lag_seconds
      @lag_mutex.synchronize do
        return 0.0 if @dispatch_count.zero?

        @total_lag_ns.to_f / @dispatch_count / 1_000_000_000.0
      end
    end

    # Registers an FSMSession for execution and returns a completion queue.
    #
    # The session and its completion queue are handed off to the EventLoop thread
    # via the queue payload, so +@fsms+ and +@waiting+ are exclusively written
    # and read by the EventLoop thread. No Mutex is required.
    #
    # The caller blocks on +completion_queue.pop+ to receive the final context
    # (WorkflowContext) once the workflow finishes or halts. If an error occurred,
    # the popped value will be an Exception — callers are responsible for re-raising it.
    #
    # @param fsm_session [Phronomy::FSMSession]
    # @return [Phronomy::AsyncQueue] resolves to final/halted context, or an Exception
    # @api private
    def register(fsm_session)
      if Phronomy::EventLoop.current?
        raise Phronomy::Error,
          "Cannot call Workflow#invoke (EventLoop mode) from within an EventLoop " \
          "entry action. Use the async IO pattern: spawn a Thread, post events " \
          "back via Phronomy::EventLoop.instance.post(...) instead."
      end

      completion_queue = Phronomy::AsyncQueue.new
      # Pass both session and completion_queue in the event payload so that the
      # EventLoop thread is the sole writer of @fsms and @waiting.
      @queue.push([Event.new(type: :start, target_id: fsm_session.id,
        payload: {session: fsm_session, completion: completion_queue}),
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)])
      completion_queue
    end

    # Enqueues an {AgentFSM} as a fire-and-forget child session.
    #
    # Unlike {#register}, this method:
    # - Is safe to call from the EventLoop thread (entry actions).
    # - Does NOT block — no completion queue is created.
    # - Delegates `:finished`/`:error` cleanup to the EventLoop via posted events.
    #
    # @param agent_fsm [Phronomy::Agent::FSM]
    # @return [nil]
    # @api private
    def enqueue_child(agent_fsm)
      @queue.push([Event.new(type: :start, target_id: agent_fsm.id,
        payload: {session: agent_fsm, completion: nil}),
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)])
      nil
    end

    # Posts an event to the loop. Safe to call from any thread (including IO threads).
    # The current monotonic clock time is recorded so that the EventLoop can
    # measure the dispatch lag when it dequeues the event.
    #
    # @param event [Phronomy::Event]
    # @api private
    def post(event)
      @queue.push([event, Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)])
    end

    # Starts the EventLoop dispatch task under {Runtime} ownership.
    #
    # The dispatch loop runs as a {Phronomy::Task} so that {Runtime#shutdown}
    # can drain it together with all other in-flight tasks.  The task is named
    # +"event-loop"+ so that {.current?} can identify it via
    # +Task.current&.name+.
    # @return [self]
    # @api private
    def start
      return self if @task&.alive?

      # Reset shutdown state so the loop can be restarted after a stop.
      @shutdown_token = Phronomy::CancellationToken.new
      @fsm_count_mutex.synchronize { @fsm_count = 0 }
      @running = true
      @task = Phronomy::Runtime.instance.spawn(name: "event-loop") do
        run_loop
      end
      self
    end

    # Stops the EventLoop dispatch task.
    #
    # Sends a cooperative shutdown sentinel to the event queue so that the
    # dispatch task can finish any in-flight handler before exiting.  Waits up
    # to +timeout+ seconds for a clean shutdown; if the task is still alive
    # afterwards it is cancelled (cooperative cancellation via {Task#cancel!}).
    #
    # @param timeout [Numeric] seconds to wait for cooperative shutdown. Defaults
    #   to +Phronomy.configuration.event_loop_stop_grace_seconds+ (5 s).
    # @param drain [Boolean] when +true+, wait for all active FSMSessions to
    #   complete before signalling the loop to stop.  Bounded by +timeout+.
    #   Defaults to +false+.
    # @param force_kill [Boolean] deprecated — retained for backward compatibility.
    #   When +true+, the dispatch task is cancelled via {Task#cancel!} if it does
    #   not stop within +timeout+.  +Thread#kill+ is no longer used; cooperative
    #   cancellation (raising {CancellationError}) replaces it.
    # @return [Symbol] shutdown status:
    #   - +:clean+ — loop exited cooperatively with no active sessions discarded
    #   - +:drained_with_discards+ — drain mode requested but sessions remained;
    #     they were discarded and the loop was stopped
    #   - +:timeout+ — the task did not stop in time and +force_kill:+ is +false+
    #   - +:force_killed+ — the task was cancelled because it did not stop in time
    # @api private
    def stop(timeout: Phronomy.configuration.event_loop_stop_grace_seconds, drain: false, force_kill: false)
      @shutdown_token.cancel!
      status = :clean

      if drain
        # Wait for active sessions to finish, bounded by timeout.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @fsm_count_mutex.synchronize do
          while @fsm_count > 0
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0
            @fsm_count_cond.wait(@fsm_count_mutex, remaining)
          end
          status = :drained_with_discards if @fsm_count > 0
        end
      end

      @running = false
      @queue.push(:__stop__)   # unblock queue.pop so the task can see @running = false
      begin
        @task&.join(timeout)
      rescue
        # Task may have terminated with an error (e.g. simulated crash in tests).
        # Suppress the re-raise so the cleanup below always runs.
        nil
      end
      if @task&.alive?
        if force_kill
          Phronomy.configuration.logger&.warn(
            "[Phronomy] EventLoop task did not stop within #{timeout}s; cancelling. " \
            "This is a last resort — check for blocking operations in event handlers."
          )
          @task.cancel!
          status = :force_killed
        else
          Phronomy.configuration.logger&.warn(
            "[Phronomy] EventLoop task did not stop within #{timeout}s; abandoning " \
            "(force_kill: false). Check for blocking operations in event handlers."
          )
          status = :timeout
        end
      end
      @task = nil
      status
    end

    private

    def run_loop
      while @running
        item = @queue.pop
        # :__stop__ is used purely as an unblock signal for @queue.pop; the
        # actual stop condition is @running == false (set before the push).
        # Treating it as `next` instead of `break` prevents a stale sentinel
        # (left by a previous stop call that raced with thread start) from
        # immediately terminating a freshly restarted EventLoop.
        next if item == :__stop__

        # item is [event, posted_at_ns] — unwrap and measure lag
        event, posted_at_ns = item
        dequeued_at_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        lag_ns = dequeued_at_ns - posted_at_ns
        update_lag_metrics(lag_ns)
        check_starvation_lag(lag_ns, event)

        dispatch_start_ns = dequeued_at_ns
        case event.type
        when :finished, :halted, :error
          # All three terminal events share the same cleanup path.
          # Both @fsms and @waiting are exclusively owned by this thread.
          @fsms.delete(event.target_id)
          cq = @waiting.delete(event.target_id)
          cq&.push(event.payload)
          # Decrement active FSM count and signal drain waiters.
          @fsm_count_mutex.synchronize do
            @fsm_count -= 1
            @fsm_count_cond.signal if @fsm_count <= 0
          end

        when :start
          # session and completion_queue arrive together in the payload so that
          # this thread is the sole writer of @fsms and @waiting.
          # completion may be nil for fire-and-forget child sessions (AgentFSM).
          session = event.payload[:session]
          cq = event.payload[:completion]

          # When shutdown has been requested, reject new sessions with a
          # CancellationError rather than starting new LLM calls that would
          # be interrupted by force-kill.
          if @shutdown_token.cancelled? && cq
            cq.push(Phronomy::CancellationError.new("EventLoop is shutting down"))
            next
          end

          @fsms[event.target_id] = session
          @waiting[event.target_id] = cq if cq
          @fsm_count_mutex.synchronize { @fsm_count += 1 }
          session.start

        else
          fsm = @fsms[event.target_id]
          if fsm
            fsm.handle(event)
          else
            # Warn when an event is dropped due to an unknown target_id so that
            # mis-typed IDs and handler-deregistration races are visible.
            warn "[Phronomy::EventLoop] Dropped event #{event.type.inspect} — " \
                 "no handler for target_id #{event.target_id.inspect}"
          end
        end

        # Check how long this dispatch took; warn if it exceeds the threshold.
        check_dispatch_time(dispatch_start_ns, event)
      end
    rescue => e
      # Unblock all waiting callers if the loop dies unexpectedly.
      @waiting.values.each { |cq| cq.push(e) }
      raise
    end

    def update_lag_metrics(lag_ns)
      @lag_mutex.synchronize do
        @last_lag_ns = lag_ns
        @max_lag_ns = lag_ns if lag_ns > @max_lag_ns
        @total_lag_ns += lag_ns
        @dispatch_count += 1
      end
    end

    def check_starvation_lag(lag_ns, event)
      threshold = Phronomy.configuration.event_loop_starvation_threshold_seconds
      return unless threshold && lag_ns > (threshold * 1_000_000_000)

      Phronomy.configuration.logger&.warn do
        "[Phronomy::EventLoop] Starvation detected: event #{event.type.inspect} " \
        "for target #{event.target_id.inspect} waited " \
        "#{format("%.3f", lag_ns / 1_000_000_000.0)}s in queue " \
        "(threshold: #{threshold}s)"
      end
    end

    def check_dispatch_time(dispatch_start_ns, event)
      threshold = Phronomy.configuration.event_loop_dispatch_threshold_seconds
      return unless threshold

      elapsed_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - dispatch_start_ns
      return unless elapsed_ns > (threshold * 1_000_000_000)

      Phronomy.configuration.logger&.warn do
        "[Phronomy::EventLoop] Long dispatch: event #{event.type.inspect} " \
        "for target #{event.target_id.inspect} took " \
        "#{format("%.3f", elapsed_ns / 1_000_000_000.0)}s on the EventLoop thread " \
        "(threshold: #{threshold}s). Consider moving blocking work to BlockingAdapterPool."
      end
    end
  end
end
