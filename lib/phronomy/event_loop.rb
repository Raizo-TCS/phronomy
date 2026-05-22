# frozen_string_literal: true

module Phronomy
  # Singleton event loop that manages all FSMSession instances.
  #
  # A single background thread reads from a global Thread::Queue and dispatches
  # events to their target FSMSession. IO work (LLM calls, tool calls) runs in
  # separate IO threads that post events back to the loop via EventLoop#post.
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

    # Stops and destroys the singleton. Primarily used in tests.
    # @api private
    def self.reset!
      @instance&.stop
      @instance = nil
    end

    def initialize
      @queue = Thread::Queue.new  # global event queue (thread-safe; no Mutex needed)
      @fsms = {}                 # { id => FSMSession }     — EventLoop thread only
      @waiting = {}                 # { id => completion_queue } — EventLoop thread only
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
    # @return [Thread::Queue] resolves to final/halted context, or an Exception
    def register(fsm_session)
      if Thread.current[:phronomy_event_loop_thread]
        raise Phronomy::Error,
          "Cannot call Workflow#invoke (EventLoop mode) from within an EventLoop " \
          "entry action. Use the async IO pattern: spawn a Thread, post events " \
          "back via Phronomy::EventLoop.instance.post(...) instead."
      end

      completion_queue = Thread::Queue.new
      # Pass both session and completion_queue in the event payload so that the
      # EventLoop thread is the sole writer of @fsms and @waiting.
      @queue.push(Event.new(type: :start, target_id: fsm_session.id,
        payload: {session: fsm_session, completion: completion_queue}))
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
    def enqueue_child(agent_fsm)
      @queue.push(Event.new(type: :start, target_id: agent_fsm.id,
        payload: {session: agent_fsm, completion: nil}))
      nil
    end

    # Posts an event to the loop. Safe to call from any thread (including IO threads).
    #
    # @param event [Phronomy::Event]
    def post(event)
      @queue.push(event)
    end

    # Starts the background event loop thread.
    # @return [self]
    def start
      @running = true
      @thread = Thread.new do
        Thread.current[:phronomy_event_loop_thread] = true
        run_loop
      end
      @thread.abort_on_exception = false
      self
    end

    # Stops the background thread. Used in tests only.
    #
    # Sends a cooperative shutdown sentinel to the event queue so that the
    # worker thread can finish any in-flight handler before exiting.  Waits up
    # to +timeout+ seconds for a clean shutdown; if the thread is still alive
    # afterwards it is force-killed as a last resort.
    #
    # @param timeout [Numeric] seconds to wait for cooperative shutdown (default 5)
    # @api private
    def stop(timeout: 5)
      @running = false
      @queue.push(:__stop__)   # unblock queue.pop so the worker can see @running = false
      @thread&.join(timeout)
      @thread&.kill if @thread&.alive?  # fallback after timeout
      @thread = nil
    end

    private

    def run_loop
      while @running
        event = @queue.pop
        break if event == :__stop__  # cooperative shutdown sentinel

        case event.type
        when :finished, :halted, :error
          # All three terminal events share the same cleanup path.
          # Both @fsms and @waiting are exclusively owned by this thread.
          @fsms.delete(event.target_id)
          cq = @waiting.delete(event.target_id)
          cq&.push(event.payload)

        when :start
          # session and completion_queue arrive together in the payload so that
          # this thread is the sole writer of @fsms and @waiting.
          # completion may be nil for fire-and-forget child sessions (AgentFSM).
          @fsms[event.target_id] = event.payload[:session]
          cq = event.payload[:completion]
          @waiting[event.target_id] = cq if cq
          event.payload[:session].start

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
      end
    rescue => e
      # Unblock all waiting callers if the loop dies unexpectedly.
      @waiting.values.each { |cq| cq.push(e) }
      raise
    end
  end
end
