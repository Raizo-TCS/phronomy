# frozen_string_literal: true

module Phronomy
  # Runtime-owned event loop that manages all FSMSession instances.
  #
  # A dedicated real thread reads from a Runtime-local AsyncQueue and dispatches
  # events to their target FSMSession. The EventLoop is created at most once by
  # its owning Runtime and is never restarted after shutdown.
  #
  # FSMSession handlers run on the EventLoop thread. They must not perform
  # blocking work or call synchronous invoke APIs from that thread.
  class EventLoop
    SYSTEM_CHANNEL_ID = "__event_loop__"

    QUEUE_BACKLOG_WARNING_THRESHOLD = 1_000
    QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS = 60.0

    STOP = Object.new.freeze
    private_constant :STOP

    # @param runtime [Phronomy::Runtime] owning Runtime
    # @api private
    def initialize(runtime:)
      @runtime = runtime
      @queue = Phronomy::Concurrency::AsyncQueue.new
      @queue_metrics_mutex = Mutex.new
      @queue_depth = 0
      @max_queue_depth = 0
      @last_queue_backlog_warning_at = nil
      @fsms = {}
      @waiting = {}

      @lifecycle_mutex = Mutex.new
      @idle_cond = ConditionVariable.new
      @shutdown_mutex = Mutex.new
      @state = :running
      @outstanding_sessions = 0
      @cancel_requested = false
      @shutdown_status = nil

      @lag_mutex = Mutex.new
      @last_lag_ns = 0
      @max_lag_ns = 0
      @dispatch_count = 0
      @total_lag_ns = 0

      @task = @runtime.__spawn_event_loop_service { run_loop }
    end

    # @return [Float]
    # @api private
    def last_lag_seconds
      @lag_mutex.synchronize { @last_lag_ns } / 1_000_000_000.0
    end

    # @return [Float]
    # @api private
    def max_lag_seconds
      @lag_mutex.synchronize { @max_lag_ns } / 1_000_000_000.0
    end

    # @return [Float]
    # @api private
    def average_lag_seconds
      @lag_mutex.synchronize do
        return 0.0 if @dispatch_count.zero?

        @total_lag_ns.to_f / @dispatch_count / 1_000_000_000.0
      end
    end

    # Number of events currently waiting in the EventLoop queue.
    # The event being dispatched is not included.
    # @return [Integer]
    # @api private
    def queue_depth
      @queue_metrics_mutex.synchronize { @queue_depth }
    end

    # Highest EventLoop queue depth observed during this Runtime lifetime.
    # @return [Integer]
    # @api private
    def max_queue_depth
      @queue_metrics_mutex.synchronize { @max_queue_depth }
    end

    # Registers an FSMSession and returns its completion queue.
    #
    # +outstanding_sessions+ is incremented before the :start event is enqueued,
    # so shutdown also accounts for accepted sessions that have not yet been
    # dispatched.
    #
    # @param fsm_session [Phronomy::FSMSession]
    # @param completion [Phronomy::Task, nil]
    # @return [Phronomy::Concurrency::AsyncQueue, Phronomy::Task]
    # @api private
    def register(fsm_session, completion: nil)
      if current? && !completion.is_a?(Phronomy::Task)
        raise Phronomy::Error,
          "Cannot call synchronous Workflow#invoke from an EventLoop action. " \
          "Schedule work asynchronously instead."
      end

      completion_queue = completion || Phronomy::Concurrency::AsyncQueue.new
      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler && completion_queue.respond_to?(:expect_cross_thread_push)
        completion_queue.expect_cross_thread_push(scheduler)
      end

      event = Phronomy::Event.new(
        type: :start,
        target_id: SYSTEM_CHANNEL_ID,
        payload: {session: fsm_session, completion: completion_queue}
      )
      queued_depth = nil

      @lifecycle_mutex.synchronize do
        ensure_accepting_registrations!
        @outstanding_sessions += 1
        begin
          queued_depth = enqueue([event, monotonic_nanoseconds])
        rescue
          @outstanding_sessions -= 1
          @idle_cond.broadcast if @outstanding_sessions.zero?
          raise
        end
      end

      check_queue_backlog(queued_depth, event)
      completion_queue
    end

    # Posts an event. Returns false after stopping begins.
    #
    # Async completion callbacks may race with shutdown, so rejection is a
    # boolean result rather than an exception.
    #
    # @param event [Phronomy::Event]
    # @return [Boolean]
    # @api private
    def post(event)
      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events?

        queued_depth = enqueue([event, monotonic_nanoseconds])
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    # Returns true only for this EventLoop's dispatcher Task.
    # @api private
    def current?
      Phronomy::Task.current.equal?(@task)
    end

    # @return [Symbol]
    # @api private
    def state
      @lifecycle_mutex.synchronize { @state }
    end

    # Stops external admission at the Runtime boundary while allowing already
    # accepted work to complete on this EventLoop.
    # @api private
    def begin_draining
      @lifecycle_mutex.synchronize do
        @state = :draining if @state == :running
      end
      self
    end

    # @return [Boolean]
    # @api private
    def idle?
      @lifecycle_mutex.synchronize { @outstanding_sessions.zero? }
    end

    # Waits until no queued :start or active session remains.
    # @param deadline [Numeric] absolute monotonic deadline
    # @return [Boolean] false on timeout
    # @api private
    def wait_until_idle(deadline)
      @lifecycle_mutex.synchronize do
        until @outstanding_sessions.zero?
          remaining = deadline - monotonic_now
          return false if remaining <= 0

          @idle_cond.wait(@lifecycle_mutex, remaining)
        end
        true
      end
    end

    # Runtime-only terminal shutdown.
    #
    # On graceful timeout the dispatcher is cancelled. It cleans abandoned
    # waiters from its own thread before exiting so Task completion callbacks
    # retain EventLoop thread affinity. An idempotent post-join cleanup remains
    # as a defensive fallback.
    #
    # @param deadline [Numeric] absolute monotonic deadline
    # @param cancel_grace [Numeric] seconds to wait after Task#cancel!
    # @return [Symbol] :terminated, :cancelled, :cancel_timeout, or :failed
    # @api private
    def shutdown(deadline:, cancel_grace:)
      @shutdown_mutex.synchronize do
        return @shutdown_status if @shutdown_status

        if state == :failed
          join_until(deadline)
          @shutdown_status = :failed
          return @shutdown_status
        end

        begin_draining
        if wait_until_idle(deadline)
          begin_stopping_if_idle
          join_until(deadline)
        end

        @shutdown_status = if task_alive?
          cancel_and_cleanup(cancel_grace)
        elsif state == :failed
          :failed
        else
          finalize_terminated(:terminated)
        end
      end
    end

    # @return [Boolean]
    # @api private
    def task_alive?
      @task&.alive? || false
    end

    private

    def run_loop
      loop do
        item = dequeue
        break if item.equal?(STOP)

        event, posted_at_ns = item
        dequeued_at_ns = monotonic_nanoseconds
        lag_ns = dequeued_at_ns - posted_at_ns
        update_lag_metrics(lag_ns)
        check_starvation_lag(lag_ns, event)

        dispatch_start_ns = dequeued_at_ns
        dispatch(event)
        check_dispatch_time(dispatch_start_ns, event)
      end
    rescue Phronomy::CancellationError => error
      if shutdown_cancel_requested?
        cleanup_abandoned_work(
          Phronomy::CancellationError.new("Runtime shutdown timed out")
        )
      else
        notify_unexpected_dispatcher_failure(error)
        raise
      end
    rescue => error
      notify_unexpected_dispatcher_failure(error)
      raise
    ensure
      @lifecycle_mutex.synchronize { @idle_cond.broadcast }
    end

    def dispatch(event)
      if event.target_id == SYSTEM_CHANNEL_ID
        dispatch_management(event)
      else
        fsm = @fsms[event.target_id]
        if fsm
          fsm.handle(event)
        else
          warn "[Phronomy::EventLoop] Dropped event #{event.type.inspect} — " \
               "no handler for target_id #{event.target_id.inspect}"
        end
      end
    end

    def dispatch_management(event)
      case event.type
      when :finished, :halted, :error
        session_id = event.payload[:session_id]
        session = @fsms.delete(session_id)
        waiter = @waiting.delete(session_id)
        complete_waiter(waiter, event.payload[:result])
        decrement_outstanding if session
      when :start
        session = event.payload[:session]
        waiter = event.payload[:completion]
        @fsms[session.id] = session
        @waiting[session.id] = waiter if waiter
        session.start
      end
    end

    def begin_stopping_if_idle
      @lifecycle_mutex.synchronize do
        return false unless @state == :draining
        return false unless @outstanding_sessions.zero?

        @state = :stopping
        enqueue(STOP)
        true
      end
    end

    def cancel_and_cleanup(cancel_grace)
      task = @task
      @lifecycle_mutex.synchronize do
        @state = :stopping unless @state == :failed
        @cancel_requested = true
      end

      task&.cancel!
      begin
        task&.join(cancel_grace)
      rescue
        nil
      end

      if task&.alive?
        @lifecycle_mutex.synchronize { @state = :failed }
        return :cancel_timeout
      end

      return :failed if state == :failed

      # Normally already performed by run_loop on the dispatcher thread. This
      # second call is idempotent and covers cancellation before run_loop enters
      # its rescue path. Stream completion has its own affinity guard, so the
      # fallback never invokes an Application listener from this thread.
      cleanup_abandoned_work(
        Phronomy::CancellationError.new("Runtime shutdown timed out")
      )
      finalize_terminated(:cancelled)
    end

    # Safe to call repeatedly; the first call drains and clears all waiters.
    def cleanup_abandoned_work(error)
      drain_queued_items.each do |item|
        next if item.equal?(STOP)

        event, = item
        next unless event.target_id == SYSTEM_CHANNEL_ID && event.type == :start

        complete_waiter(event.payload[:completion], error)
      end

      @waiting.values.each { |waiter| complete_waiter(waiter, error) }
      @waiting.clear
      @fsms.clear
      @lifecycle_mutex.synchronize do
        @outstanding_sessions = 0
        @idle_cond.broadcast
      end
    end

    def drain_queued_items
      items = []
      loop do
        item = dequeue(timeout: 0)
        break unless item

        items << item
      end
      items
    end

    # Framework failures are reported and made terminal. No automatic restart,
    # replay, or pending-queue recovery is attempted.
    def notify_unexpected_dispatcher_failure(error)
      @lifecycle_mutex.synchronize do
        @state = :failed
        @idle_cond.broadcast
      end
      @waiting.values.each { |waiter| complete_waiter(waiter, error) }
      @runtime.__event_loop_failed(error)
    end

    def shutdown_cancel_requested?
      @lifecycle_mutex.synchronize do
        @cancel_requested && @state == :stopping
      end
    end

    def accepting_events?
      %i[running draining].include?(@state)
    end

    def ensure_accepting_registrations!
      return if accepting_events?

      raise Phronomy::RuntimeShutdownError,
        "EventLoop is #{@state}; new sessions are not accepted"
    end

    def decrement_outstanding
      @lifecycle_mutex.synchronize do
        @outstanding_sessions -= 1 if @outstanding_sessions.positive?
        @idle_cond.broadcast if @outstanding_sessions.zero?
      end
    end

    def join_until(deadline)
      remaining = deadline - monotonic_now
      return if remaining <= 0

      begin
        @task&.join(remaining)
      rescue
        nil
      end
    end

    def finalize_terminated(status)
      @lifecycle_mutex.synchronize do
        @state = :terminated
        @task = nil unless @task&.alive?
        @idle_cond.broadcast
      end
      status
    end

    def complete_waiter(waiter, payload)
      return unless waiter

      if waiter.is_a?(Phronomy::Task)
        if payload.is_a?(Exception)
          waiter.backend.unblock(nil, payload)
          waiter.transition!(:failed, error: payload)
        else
          waiter.backend.unblock(payload, nil)
          waiter.transition!(:completed, value: payload)
        end
      else
        waiter.push(payload)
      end
    end

    def enqueue(item)
      depth = @queue_metrics_mutex.synchronize do
        @queue_depth += 1
        @max_queue_depth = @queue_depth if @queue_depth > @max_queue_depth
        @queue_depth
      end
      @queue.push(item)
      depth
    rescue
      @queue_metrics_mutex.synchronize do
        @queue_depth -= 1 if @queue_depth.positive?
      end
      raise
    end

    def dequeue(timeout: nil)
      item = nil
      begin
        item = @queue.pop(timeout: timeout)
      ensure
        if item
          @queue_metrics_mutex.synchronize do
            @queue_depth -= 1 if @queue_depth.positive?
          end
        end
      end
      item
    end

    def check_queue_backlog(depth, event)
      return unless depth >= QUEUE_BACKLOG_WARNING_THRESHOLD

      now = monotonic_now
      max_depth = nil
      should_warn = @queue_metrics_mutex.synchronize do
        last = @last_queue_backlog_warning_at
        next false if last && (now - last) < QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS

        @last_queue_backlog_warning_at = now
        max_depth = @max_queue_depth
        true
      end
      return unless should_warn

      warn_queue_backlog(
        "[Phronomy::EventLoop] Queue backlog is high: " \
        "depth=#{depth} max_depth=#{max_depth} " \
        "threshold=#{QUEUE_BACKLOG_WARNING_THRESHOLD} " \
        "event=#{event.type.inspect} target_id=#{event.target_id.inspect}. " \
        "Events are not dropped; inspect slow callbacks or high streaming concurrency."
      )
    end

    def warn_queue_backlog(message)
      logger = Phronomy.configuration.logger
      if logger
        logger.warn(message)
      else
        Kernel.warn(message)
      end
    rescue
      nil
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

      elapsed_ns = monotonic_nanoseconds - dispatch_start_ns
      return unless elapsed_ns > (threshold * 1_000_000_000)

      Phronomy.configuration.logger&.warn do
        "[Phronomy::EventLoop] Long dispatch: event #{event.type.inspect} " \
          "for target #{event.target_id.inspect} took " \
          "#{format("%.3f", elapsed_ns / 1_000_000_000.0)}s on the EventLoop thread " \
          "(threshold: #{threshold}s). Consider moving blocking work to BlockingAdapterPool."
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def monotonic_nanoseconds
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end
end
