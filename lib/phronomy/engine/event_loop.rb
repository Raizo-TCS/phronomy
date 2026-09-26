# frozen_string_literal: true

require_relative "concurrency/worker_input_restricted"

module Phronomy
  # Runtime-owned FIFO event loop for FSMSession instances.
  #
  # EventLoop owns the framework's sole control-plane OS thread. All session
  # lifecycle progression and Phronomy-managed live execution-state mutation
  # happens by short event dispatches on this thread.
  class EventLoop
    include Phronomy::Concurrency::WorkerInputRestricted

    SYSTEM_CHANNEL_ID = "__event_loop__"

    QUEUE_BACKLOG_WARNING_THRESHOLD = 1_000
    QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS = 60.0

    TERMINAL_MANAGEMENT_EVENTS = %i[finished halted error recovery_required].freeze
    private_constant :TERMINAL_MANAGEMENT_EVENTS

    STOP = Object.new.freeze
    WAKE = Object.new.freeze
    private_constant :STOP, :WAKE

    def initialize(runtime:)
      @runtime = runtime
      @queue = Phronomy::Concurrency::AsyncQueue.new
      @queue_metrics_mutex = Mutex.new
      @queue_depth = 0
      @max_queue_depth = 0
      @last_queue_backlog_warning_at = nil

      @execution_receivers = {}
      @execution_deliveries = {}
      @session_receivers = {}
      @dispatching_delivery = nil
      @receiver_shutdown_error = nil
      @fsms = {}
      @waiting = {}
      @admitted_fsm_session_ids = Set.new

      @lifecycle_mutex = Mutex.new
      @idle_cond = ConditionVariable.new
      @shutdown_mutex = Mutex.new
      @state = :running
      @outstanding_sessions = 0
      @shutdown_status = nil

      @lag_mutex = Mutex.new
      @last_lag_ns = 0
      @max_lag_ns = 0
      @dispatch_count = 0
      @total_lag_ns = 0

      @thread = Thread.new { run_loop }
      @thread.name = "phronomy-event-loop"
    end

    def last_lag_seconds
      @lag_mutex.synchronize { @last_lag_ns } / 1_000_000_000.0
    end

    def max_lag_seconds
      @lag_mutex.synchronize { @max_lag_ns } / 1_000_000_000.0
    end

    def average_lag_seconds
      @lag_mutex.synchronize do
        return 0.0 if @dispatch_count.zero?
        @total_lag_ns.to_f / @dispatch_count / 1_000_000_000.0
      end
    end

    def queue_depth
      @queue_metrics_mutex.synchronize { @queue_depth }
    end

    def max_queue_depth
      @queue_metrics_mutex.synchronize { @max_queue_depth }
    end

    # Internal receiver registration is closed before shutdown tests idleness.
    # Feature constructors are side-effect free and run outside this lock.
    # @api private
    def __register_execution_receiver(key:, receiver:)
      unless receiver.is_a?(Phronomy::ExecutionReceiver) && receiver.__bound_to?(self)
        raise ArgumentError, "execution receiver must implement the Engine contract for this EventLoop"
      end
      @lifecycle_mutex.synchronize do
        unless @state == :running
          raise Phronomy::RuntimeShutdownError,
            "EventLoop is #{@state}; execution receivers cannot be registered"
        end
        @execution_receivers[key] ||= receiver
      end
    end

    # @api private
    def __execution_receiver(key:)
      @lifecycle_mutex.synchronize { @execution_receivers[key] }
    end

    # The same lock covers feature state and Engine's idle decision. Blocks are
    # short state reads/writes, never I/O, delivery callbacks or Runtime calls.
    # @api private
    def __synchronize_execution_state
      @lifecycle_mutex.synchronize do
        yield
      ensure
        @idle_cond.broadcast if runtime_idle_locked?
      end
    end

    # Admission already queued while running may establish its feature slot
    # during drain. A newly requested admission may not do so.
    # @api private
    def __admit_execution(receiver)
      assert_event_loop_thread!
      __synchronize_execution_state do
        accepted_delivery = @dispatching_delivery &&
          @dispatching_delivery[:receiver].equal?(receiver) &&
          @dispatching_delivery[:admission]
        accepting = @execution_receivers.value?(receiver) &&
          (@state == :running || (@state == :draining && accepted_delivery))
        unless accepting
          raise Phronomy::RuntimeShutdownError,
            "EventLoop is #{@state}; new executions are not accepted"
        end
        yield
      end
    end

    # Count accepted deliveries until dispatch finishes, including the interval
    # before a feature admission or FSM exists. Continuations use registered
    # receivers; new admissions require the running state.
    # @api private
    def __post_execution(receiver, message, admission: false, completion: nil)
      token = Object.new.freeze
      event = Phronomy::Event.new(type: :execution_control,
        target_id: SYSTEM_CHANNEL_ID, payload: token)
      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events? && @execution_receivers.value?(receiver)
        next false if admission && @state != :running

        @execution_deliveries[token] = {
          receiver: receiver, message: message, admission: admission, completion: completion
        }.freeze
        begin
          queued_depth = enqueue([event, monotonic_nanoseconds])
        rescue
          @execution_deliveries.delete(token)
          raise
        end
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    # @api private
    def __receiver_cleanup_complete?
      @receiver_shutdown_error.nil?
    end

    def register(fsm_session, completion: nil, receiver: nil)
      if current? && !completion.is_a?(Phronomy::TaskResult)
        raise Phronomy::Error,
          "Cannot call a synchronous invocation API from an EventLoop action. " \
          "Schedule work asynchronously instead."
      end

      completion_handle = completion || Phronomy::Concurrency::AsyncQueue.new
      event = Phronomy::Event.new(
        type: :start,
        target_id: SYSTEM_CHANNEL_ID,
        payload: {session: fsm_session, completion: completion_handle}
      )
      queued_depth = nil

      @lifecycle_mutex.synchronize do
        ensure_accepting_registrations!
        if @admitted_fsm_session_ids.include?(fsm_session.id)
          raise Phronomy::Error,
            "FSMSession #{fsm_session.id.inspect} is already registered"
        end

        if receiver && !@execution_receivers.value?(receiver)
          raise ArgumentError, "execution receiver is not registered on this EventLoop"
        end
        @session_receivers[fsm_session.id] = receiver if receiver
        @admitted_fsm_session_ids.add(fsm_session.id)
        @outstanding_sessions += 1
        begin
          queued_depth = enqueue([event, monotonic_nanoseconds])
        rescue
          @session_receivers.delete(fsm_session.id)
          @admitted_fsm_session_ids.delete(fsm_session.id)
          @outstanding_sessions -= 1
          @idle_cond.broadcast if runtime_idle_locked?
          raise
        end
      end

      check_queue_backlog(queued_depth, event)
      completion_handle
    end

    def post(event)
      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events?

        terminal_fsm_session_id = nil
        if terminal_management_event?(event)
          terminal_fsm_session_id = event.payload.fetch(:fsm_session_id)
          @admitted_fsm_session_ids.delete(terminal_fsm_session_id)
        end

        begin
          queued_depth = enqueue([event, monotonic_nanoseconds])
        rescue
          @admitted_fsm_session_ids.add(terminal_fsm_session_id) if terminal_fsm_session_id
          raise
        end
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    def post_to_session(event)
      if event.target_id == SYSTEM_CHANNEL_ID
        raise ArgumentError, "post_to_session cannot target the system channel"
      end

      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events?
        next false unless @admitted_fsm_session_ids.include?(event.target_id)

        queued_depth = enqueue([event, monotonic_nanoseconds])
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    # Resolve feature identity and enqueue to a live FSM under one lock. The
    # receiver supplies only a short lookup; dispatch still uses the FIFO.
    # @api private
    def __route_execution_event(receiver)
      event = nil
      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events? && @execution_receivers.value?(receiver)
        event = yield
        next false unless event && @admitted_fsm_session_ids.include?(event.target_id)

        queued_depth = enqueue([event, monotonic_nanoseconds])
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    # @api private
    def fsm_session_state(fsm_session_id)
      assert_event_loop_thread!
      @fsms[fsm_session_id.to_s]&.current_state
    end

    def wake
      @queue.push(WAKE)
      true
    rescue ClosedQueueError
      false
    end

    def admitted_fsm_session?(fsm_session_id)
      @lifecycle_mutex.synchronize { @admitted_fsm_session_ids.include?(fsm_session_id) }
    end

    def current?
      Thread.current.equal?(@thread)
    end

    def state
      @lifecycle_mutex.synchronize { @state }
    end

    def begin_draining
      @lifecycle_mutex.synchronize do
        @state = :draining if @state == :running
      end
      self
    end

    def idle?
      @lifecycle_mutex.synchronize { runtime_idle_locked? }
    end

    def wait_until_idle(deadline)
      @lifecycle_mutex.synchronize do
        until runtime_idle_locked?
          remaining = deadline - monotonic_now
          return false if remaining <= 0
          @idle_cond.wait(@lifecycle_mutex, remaining)
        end
        true
      end
    end

    def stop_and_join(deadline:)
      @shutdown_mutex.synchronize do
        return @shutdown_status if @shutdown_status

        if state == :failed
          join_until(deadline)
          @shutdown_status = :failed
          return @shutdown_status
        end

        begin_stopping_if_idle
        join_until(deadline)

        @shutdown_status = if thread_alive?
          @lifecycle_mutex.synchronize { @state = :failed }
          :cancel_timeout
        elsif state == :failed
          :failed
        else
          finalize_terminated(:terminated)
        end
      end
    end

    def shutdown(deadline:, cancel_grace: deadline)
      stop_and_join(deadline: deadline)
    end

    def thread_alive?
      @thread&.alive? || false
    end

    alias_method :task_alive?, :thread_alive?

    private

    def dispatch_execution(token)
      delivery = @lifecycle_mutex.synchronize { @execution_deliveries[token] }
      return unless delivery

      @dispatching_delivery = delivery
      delivery[:receiver].deliver(delivery[:message])
    rescue => error
      complete_waiter(delivery[:completion], error) if delivery
      raise
    ensure
      @dispatching_delivery = nil
      @lifecycle_mutex.synchronize do
        @execution_deliveries.delete(token)
        @idle_cond.broadcast if runtime_idle_locked?
      end
    end

    def run_loop
      loop do
        fire_due_timers
        timeout = @runtime.__timer_queue.seconds_until_next
        item = dequeue(timeout: timeout)
        next if item.nil? || item.equal?(WAKE)
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
      fire_due_timers
    rescue => error
      notify_unexpected_dispatcher_failure(error)
      raise
    ensure
      @lifecycle_mutex.synchronize { @idle_cond.broadcast }
    end

    def fire_due_timers
      @runtime.__timer_queue.fire_due
    end

    def dispatch(event)
      if event.target_id == SYSTEM_CHANNEL_ID
        dispatch_management(event)
        return
      end

      fsm = @fsms[event.target_id]
      if fsm
        fsm.handle(event)
      else
        warn(
          "[Phronomy::EventLoop] Dropped event #{event.type.inspect} — " \
          "no handler for target_id #{event.target_id.inspect}"
        )
      end
    end

    def dispatch_management(event)
      case event.type
      when :finished, :halted, :error
        fsm_session_id = event.payload.fetch(:fsm_session_id)
        session = @fsms.delete(fsm_session_id)
        waiter = @waiting.delete(fsm_session_id)
        decrement_outstanding if session
        @lifecycle_mutex.synchronize { @session_receivers.delete(fsm_session_id) }
        complete_waiter(waiter, event.payload.fetch(:result))
      when :start
        session = event.payload.fetch(:session)
        waiter = event.payload[:completion]
        @fsms[session.id] = session
        @waiting[session.id] = waiter if waiter
        session.start
      when :execution_control
        dispatch_execution(event.payload)
      when :recovery_required
        fsm_session_id = event.payload.fetch(:fsm_session_id)
        session = @fsms.delete(fsm_session_id)
        decrement_outstanding if session
        receiver = @lifecycle_mutex.synchronize { @session_receivers.delete(fsm_session_id) }
        receiver&.session_retired(fsm_session_id, reason: :recovery_required)
      end
    end

    def terminal_management_event?(event)
      event.target_id == SYSTEM_CHANNEL_ID &&
        TERMINAL_MANAGEMENT_EVENTS.include?(event.type) &&
        event.payload.is_a?(Hash) &&
        event.payload.key?(:fsm_session_id)
    end

    def begin_stopping_if_idle
      @lifecycle_mutex.synchronize do
        return false unless @state == :draining
        return false unless runtime_idle_locked?

        @state = :stopping
        @queue.push(STOP)
        true
      end
    end

    def cleanup_abandoned_work(error)
      drain_queued_items.each do |item|
        next if item.equal?(STOP) || item.equal?(WAKE)

        event, = item
        next unless event.target_id == SYSTEM_CHANNEL_ID
        next unless event.type == :start
        complete_waiter(event.payload[:completion], error)
      end

      @waiting.values.each { |waiter| complete_waiter(waiter, error) }
      @waiting.clear
      @fsms.clear
      deliveries = @lifecycle_mutex.synchronize do
        pending = @execution_deliveries.values
        @execution_deliveries.clear
        @session_receivers.clear
        @admitted_fsm_session_ids.clear
        @outstanding_sessions = 0
        @idle_cond.broadcast
        pending
      end
      deliveries.each { |delivery| complete_waiter(delivery[:completion], error) }
      shutdown_receivers(error)
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

    def notify_unexpected_dispatcher_failure(error)
      @lifecycle_mutex.synchronize do
        @state = :failed
        @admitted_fsm_session_ids.clear
        @idle_cond.broadcast
      end
      cleanup_abandoned_work(error)
      @runtime.__event_loop_failed(error)
    end

    def accepting_events?
      %i[running draining].include?(@state)
    end

    def ensure_accepting_registrations!
      return if accepting_events?
      raise Phronomy::RuntimeShutdownError,
        "EventLoop is #{@state}; new sessions are not accepted"
    end

    def assert_event_loop_thread!
      return if current?

      raise Phronomy::Error,
        "Phronomy-managed live execution state may only be mutated on EventLoop"
    end

    def decrement_outstanding
      @lifecycle_mutex.synchronize do
        @outstanding_sessions -= 1 if @outstanding_sessions.positive?
        @idle_cond.broadcast if runtime_idle_locked?
      end
    end

    def runtime_idle_locked?
      @outstanding_sessions.zero? && @execution_deliveries.empty? &&
        @execution_receivers.values.all?(&:idle?)
    end

    def join_until(deadline)
      remaining = deadline - monotonic_now
      return if remaining <= 0
      @thread&.join(remaining)
    rescue
      nil
    end

    def finalize_terminated(status)
      @lifecycle_mutex.synchronize do
        @state = :terminated
        @admitted_fsm_session_ids.clear
        @session_receivers.clear
        @thread = nil
        @idle_cond.broadcast
      end
      shutdown_receivers(nil)
      @receiver_shutdown_error ? :failed : status
    end

    def shutdown_receivers(error)
      @execution_receivers.each_value do |receiver|
        receiver.shutdown(error: error)
      rescue => caught
        @receiver_shutdown_error ||= caught
      end
      @runtime.__event_loop_failed(@receiver_shutdown_error) if @receiver_shutdown_error
    end

    def complete_waiter(waiter, payload)
      return unless waiter

      if waiter.is_a?(Phronomy::TaskResult)
        payload.is_a?(Exception) ? waiter.fail(payload) : waiter.complete(payload)
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
        if item && !item.equal?(WAKE) && !item.equal?(STOP)
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
        if last && (now - last) < QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS
          next false
        end
        @last_queue_backlog_warning_at = now
        max_depth = @max_queue_depth
        true
      end
      return unless should_warn

      warn_queue_backlog(
        "[Phronomy::EventLoop] Queue backlog is high: " \
          "depth=#{depth} max_depth=#{max_depth} " \
          "threshold=#{QUEUE_BACKLOG_WARNING_THRESHOLD} " \
          "event=#{event.type.inspect} target_id=#{event.target_id.inspect}."
      )
    end

    def warn_queue_backlog(message)
      logger = Phronomy::RuntimeSettings.current.logger
      logger ? logger.warn(message) : Kernel.warn(message)
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
      threshold = Phronomy::RuntimeSettings.current.event_loop_starvation_threshold_seconds
      return unless threshold
      return unless lag_ns > (threshold * 1_000_000_000)

      Phronomy::RuntimeSettings.current.logger&.warn do
        "[Phronomy::EventLoop] Starvation detected: event #{event.type.inspect} " \
          "for target #{event.target_id.inspect} waited " \
          "#{format("%.3f", lag_ns / 1_000_000_000.0)}s in queue " \
          "(threshold: #{threshold}s)"
      end
    end

    def check_dispatch_time(dispatch_start_ns, event)
      threshold = Phronomy::RuntimeSettings.current.event_loop_dispatch_threshold_seconds
      return unless threshold

      elapsed_ns = monotonic_nanoseconds - dispatch_start_ns
      return unless elapsed_ns > (threshold * 1_000_000_000)

      Phronomy::RuntimeSettings.current.logger&.warn do
        "[Phronomy::EventLoop] Long dispatch: event #{event.type.inspect} " \
          "for target #{event.target_id.inspect} took " \
          "#{format("%.3f", elapsed_ns / 1_000_000_000.0)}s on the EventLoop thread " \
          "(threshold: #{threshold}s). Move blocking I/O to OffloadPool."
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
