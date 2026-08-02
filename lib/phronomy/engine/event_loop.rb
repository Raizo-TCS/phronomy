# frozen_string_literal: true

module Phronomy
  # Runtime-owned FIFO event loop for FSMSession instances.
  class EventLoop
    SYSTEM_CHANNEL_ID = "__event_loop__"

    QUEUE_BACKLOG_WARNING_THRESHOLD = 1_000
    QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS = 60.0

    TERMINAL_MANAGEMENT_EVENTS = %i[finished halted error].freeze
    private_constant :TERMINAL_MANAGEMENT_EVENTS

    STOP = Object.new.freeze
    private_constant :STOP

    def initialize(runtime:)
      @runtime = runtime
      @queue = Phronomy::Concurrency::AsyncQueue.new
      @queue_metrics_mutex = Mutex.new
      @queue_depth = 0
      @max_queue_depth = 0
      @last_queue_backlog_warning_at = nil

      # @fsms and @waiting are dispatcher-thread-owned.
      @fsms = {}
      @waiting = {}

      # Admission is shared by caller threads and the dispatcher. A session ID
      # enters this set before its :start event is queued and leaves when its
      # terminal management event is queued.
      @admitted_session_ids = Set.new

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

    def register(fsm_session, completion: nil)
      if current? && !completion.is_a?(Phronomy::Task)
        raise Phronomy::Error,
          "Cannot call a synchronous invocation API from an EventLoop action. " \
          "Schedule work asynchronously instead."
      end

      completion_queue =
        completion || Phronomy::Concurrency::AsyncQueue.new
      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler &&
          completion_queue.respond_to?(:expect_cross_thread_push)
        completion_queue.expect_cross_thread_push(scheduler)
      end

      event = Phronomy::Event.new(
        type: :start,
        target_id: SYSTEM_CHANNEL_ID,
        payload: {
          session: fsm_session,
          completion: completion_queue
        }
      )
      queued_depth = nil

      @lifecycle_mutex.synchronize do
        ensure_accepting_registrations!
        if @admitted_session_ids.include?(fsm_session.id)
          raise Phronomy::Error,
            "FSMSession #{fsm_session.id.inspect} is already registered"
        end

        @admitted_session_ids.add(fsm_session.id)
        @outstanding_sessions += 1
        begin
          queued_depth = enqueue(
            [event, monotonic_nanoseconds]
          )
        rescue
          @admitted_session_ids.delete(fsm_session.id)
          @outstanding_sessions -= 1
          @idle_cond.broadcast if @outstanding_sessions.zero?
          raise
        end
      end

      check_queue_backlog(queued_depth, event)
      completion_queue
    end

    # Internal post operation. Management terminal events close admission for
    # their session before the terminal event is enqueued.
    def post(event)
      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events?

        terminal_session_id = nil
        if terminal_management_event?(event)
          terminal_session_id = event.payload.fetch(:session_id)
          @admitted_session_ids.delete(terminal_session_id)
        end

        begin
          queued_depth = enqueue(
            [event, monotonic_nanoseconds]
          )
        rescue
          @admitted_session_ids.add(terminal_session_id) if terminal_session_id
          raise
        end
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    # Posts an event only when the target session has been admitted and has not
    # queued a terminal management event. The event remains FIFO with all other
    # EventLoop work.
    #
    # A true result reports admission, not transition success.
    def post_to_session(event)
      if event.target_id == SYSTEM_CHANNEL_ID
        raise ArgumentError,
          "post_to_session cannot target the system channel"
      end

      queued_depth = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events?
        next false unless @admitted_session_ids.include?(event.target_id)

        queued_depth = enqueue(
          [event, monotonic_nanoseconds]
        )
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, event)
      true
    end

    def admitted_session?(session_id)
      @lifecycle_mutex.synchronize do
        @admitted_session_ids.include?(session_id)
      end
    end

    def current?
      Phronomy::Task.current.equal?(@task)
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
      @lifecycle_mutex.synchronize do
        @outstanding_sessions.zero?
      end
    end

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

        @shutdown_status =
          if task_alive?
            cancel_and_cleanup(cancel_grace)
          elsif state == :failed
            :failed
          else
            finalize_terminated(:terminated)
          end
      end
    end

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
          Phronomy::CancellationError.new(
            "Runtime shutdown timed out"
          )
        )
      else
        notify_unexpected_dispatcher_failure(error)
        raise
      end
    rescue => error
      notify_unexpected_dispatcher_failure(error)
      raise
    ensure
      @lifecycle_mutex.synchronize do
        @idle_cond.broadcast
      end
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
        session_id = event.payload.fetch(:session_id)
        session = @fsms.delete(session_id)
        waiter = @waiting.delete(session_id)
        complete_waiter(
          waiter,
          event.payload.fetch(:result)
        )
        decrement_outstanding if session
      when :start
        session = event.payload.fetch(:session)
        waiter = event.payload[:completion]
        @fsms[session.id] = session
        @waiting[session.id] = waiter if waiter
        session.start
      end
    end

    def terminal_management_event?(event)
      event.target_id == SYSTEM_CHANNEL_ID &&
        TERMINAL_MANAGEMENT_EVENTS.include?(event.type) &&
        event.payload.is_a?(Hash) &&
        event.payload.key?(:session_id)
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
        @lifecycle_mutex.synchronize do
          @state = :failed
        end
        return :cancel_timeout
      end

      return :failed if state == :failed

      cleanup_abandoned_work(
        Phronomy::CancellationError.new(
          "Runtime shutdown timed out"
        )
      )
      finalize_terminated(:cancelled)
    end

    def cleanup_abandoned_work(error)
      drain_queued_items.each do |item|
        next if item.equal?(STOP)

        event, = item
        next unless event.target_id == SYSTEM_CHANNEL_ID
        next unless event.type == :start

        complete_waiter(
          event.payload[:completion],
          error
        )
      end

      @waiting.values.each do |waiter|
        complete_waiter(waiter, error)
      end
      @waiting.clear
      @fsms.clear
      @lifecycle_mutex.synchronize do
        @admitted_session_ids.clear
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

    def notify_unexpected_dispatcher_failure(error)
      @lifecycle_mutex.synchronize do
        @state = :failed
        @admitted_session_ids.clear
        @idle_cond.broadcast
      end
      @waiting.values.each do |waiter|
        complete_waiter(waiter, error)
      end
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
        if @outstanding_sessions.positive?
          @outstanding_sessions -= 1
        end
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
        @admitted_session_ids.clear
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
          waiter.transition!(
            :completed,
            value: payload
          )
        end
      else
        waiter.push(payload)
      end
    end

    def enqueue(item)
      depth = @queue_metrics_mutex.synchronize do
        @queue_depth += 1
        if @queue_depth > @max_queue_depth
          @max_queue_depth = @queue_depth
        end
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
        if last &&
            (now - last) <
                QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS
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
        "event=#{event.type.inspect} " \
        "target_id=#{event.target_id.inspect}. " \
        "Events are not dropped; inspect slow callbacks or " \
        "high streaming concurrency."
      )
    end

    def warn_queue_backlog(message)
      logger = Phronomy.configuration.logger
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
      threshold =
        Phronomy.configuration
          .event_loop_starvation_threshold_seconds
      return unless threshold
      return unless lag_ns > (threshold * 1_000_000_000)

      Phronomy.configuration.logger&.warn do
        "[Phronomy::EventLoop] Starvation detected: " \
          "event #{event.type.inspect} " \
          "for target #{event.target_id.inspect} waited " \
          "#{format("%.3f", lag_ns / 1_000_000_000.0)}s " \
          "in queue (threshold: #{threshold}s)"
      end
    end

    def check_dispatch_time(dispatch_start_ns, event)
      threshold =
        Phronomy.configuration
          .event_loop_dispatch_threshold_seconds
      return unless threshold

      elapsed_ns = monotonic_nanoseconds - dispatch_start_ns
      return unless elapsed_ns >
        (threshold * 1_000_000_000)

      Phronomy.configuration.logger&.warn do
        "[Phronomy::EventLoop] Long dispatch: " \
          "event #{event.type.inspect} " \
          "for target #{event.target_id.inspect} took " \
          "#{format("%.3f", elapsed_ns / 1_000_000_000.0)}s " \
          "on the EventLoop thread (threshold: #{threshold}s). " \
          "Consider moving blocking work to BlockingAdapterPool."
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def monotonic_nanoseconds
      Process.clock_gettime(
        Process::CLOCK_MONOTONIC,
        :nanosecond
      )
    end
  end
end
