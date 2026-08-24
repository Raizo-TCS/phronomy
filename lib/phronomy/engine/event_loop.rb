# frozen_string_literal: true

module Phronomy
  # Runtime-owned FIFO event loop for FSMSession instances.
  #
  # EventLoop owns the framework's sole control-plane OS thread. All session
  # lifecycle progression and Phronomy-managed live execution-state mutation
  # happens by short event dispatches on this thread.
  class EventLoop
    SYSTEM_CHANNEL_ID = "__event_loop__"

    QUEUE_BACKLOG_WARNING_THRESHOLD = 1_000
    QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS = 60.0

    TERMINAL_MANAGEMENT_EVENTS = %i[finished halted error].freeze
    private_constant :TERMINAL_MANAGEMENT_EVENTS

    STOP = Object.new.freeze
    WAKE = Object.new.freeze
    UNSET = Object.new.freeze
    private_constant :STOP, :WAKE, :UNSET

    # Immutable EventLoop-owned value. The map containing these records is the
    # mutable authority; records are replaced rather than mutated in place.
    AgentExecutionState = Data.define(
      :execution_id,
      :agent,
      :coordinator,
      :execution,
      :runtime_projection,
      :base_manifest,
      :invocation,
      :fsm_session_id
    )
    private_constant :AgentExecutionState

    # Read-only process-local lookup view used by approval/live-owner APIs.
    # It intentionally exposes no mutable execution, invocation, or projection.
    AgentExecutionOwner = Data.define(:execution_id, :agent, :coordinator, :status)
    private_constant :AgentExecutionOwner

    # EventLoop-owned process-local top-level execution admission. This is
    # separate from AgentExecutionState because admission begins before the
    # durable AgentExecution exists. owner_token is coordination-only and is
    # never a semantic result-authority identifier.
    AgentAdmission = Data.define(:agent_id, :owner_token, :execution_id, :state)
    private_constant :AgentAdmission

    def initialize(runtime:)
      @runtime = runtime
      @queue = Phronomy::Concurrency::AsyncQueue.new
      @queue_metrics_mutex = Mutex.new
      @queue_depth = 0
      @max_queue_depth = 0
      @last_queue_backlog_warning_at = nil

      @fsms = {}
      @waiting = {}
      @admitted_fsm_session_ids = Set.new
      @workflow_admissions = {}
      @agent_admissions = {}
      @agent_executions = {}

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

    def register(fsm_session, completion: nil)
      if current? && !completion.is_a?(Phronomy::Task)
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

        @admitted_fsm_session_ids.add(fsm_session.id)
        @outstanding_sessions += 1
        begin
          queued_depth = enqueue([event, monotonic_nanoseconds])
        rescue
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

    # Process-local read-only admission check used by destructive Agent lifecycle
    # operations. The mutable admission map itself remains EventLoop-owned.
    def agent_execution_admitted?(agent_id)
      @lifecycle_mutex.synchronize { @agent_admissions.key?(agent_id.to_s) }
    end

    # Reserves the one top-level logical execution slot for agent_id before any
    # Persistence execution admission is attempted.
    # @api private
    def admit_agent_execution(agent_id, owner_token:)
      assert_event_loop_thread!
      key = agent_id.to_s
      raise ArgumentError, "agent_id must not be empty" if key.empty?
      raise ArgumentError, "owner_token is required" unless owner_token

      @lifecycle_mutex.synchronize do
        ensure_accepting_registrations!
        if @agent_admissions.key?(key)
          raise Phronomy::AgentBusyError,
            "Agent #{key.inspect} already has a nonterminal top-level execution"
        end
        @agent_admissions[key] = AgentAdmission.new(
          agent_id: key.freeze,
          owner_token: owner_token,
          execution_id: nil,
          state: :admitting
        )
      end
      true
    end

    # Binds a successful durable AgentExecution identity to the earlier
    # process-local admission.
    # @api private
    def bind_agent_execution_admission(agent_id, owner_token:, execution_id:)
      assert_event_loop_thread!
      key = agent_id.to_s
      execution_key = execution_id.to_s
      @lifecycle_mutex.synchronize do
        current = @agent_admissions.fetch(key) do
          raise Phronomy::Error, "Agent #{key.inspect} has no Runtime admission"
        end
        unless current.owner_token.equal?(owner_token) && current.execution_id.nil?
          raise Phronomy::Error, "stale Agent admission bind for #{key.inspect}"
        end
        @agent_admissions[key] = AgentAdmission.new(
          agent_id: current.agent_id,
          owner_token: current.owner_token,
          execution_id: execution_key.freeze,
          state: :executing
        )
      end
      true
    end

    # @api private
    def mark_agent_execution_admission(agent_id, execution_id:, state:)
      assert_event_loop_thread!
      key = agent_id.to_s
      execution_key = execution_id.to_s
      next_state = state.to_sym
      unless %i[executing suspended resuming terminalizing recovery_required].include?(next_state)
        raise ArgumentError, "unsupported Agent admission state: #{next_state.inspect}"
      end

      @lifecycle_mutex.synchronize do
        current = @agent_admissions.fetch(key) do
          raise Phronomy::Error, "Agent #{key.inspect} has no Runtime admission"
        end
        unless current.execution_id.to_s == execution_key
          raise Phronomy::Error, "stale Agent admission state update for #{key.inspect}"
        end
        @agent_admissions[key] = AgentAdmission.new(
          agent_id: current.agent_id,
          owner_token: current.owner_token,
          execution_id: current.execution_id,
          state: next_state
        )
        @idle_cond.broadcast if runtime_idle_locked?
      end
      true
    end

    # @api private
    def mark_agent_admission_recovery_required(agent_id, owner_token:)
      assert_event_loop_thread!
      key = agent_id.to_s
      @lifecycle_mutex.synchronize do
        current = @agent_admissions.fetch(key) do
          raise Phronomy::Error, "Agent #{key.inspect} has no Runtime admission"
        end
        unless current.owner_token.equal?(owner_token)
          raise Phronomy::Error, "stale Agent admission recovery update for #{key.inspect}"
        end
        @agent_admissions[key] = AgentAdmission.new(
          agent_id: current.agent_id,
          owner_token: current.owner_token,
          execution_id: current.execution_id,
          state: :recovery_required
        )
        @idle_cond.broadcast if runtime_idle_locked?
      end
      true
    end

    # Owner-aware release. Pre-durable failures release by owner_token; durable
    # terminal outcomes release by execution_id.
    # @api private
    def release_agent_execution_admission(agent_id, owner_token: nil, execution_id: nil)
      assert_event_loop_thread!
      key = agent_id.to_s
      @lifecycle_mutex.synchronize do
        current = @agent_admissions[key]
        next false unless current

        authoritative = if execution_id
          current.execution_id.to_s == execution_id.to_s
        elsif owner_token
          current.owner_token.equal?(owner_token)
        else
          false
        end
        next false unless authoritative

        @agent_admissions.delete(key)
        @idle_cond.broadcast if runtime_idle_locked?
        true
      end
    end

    # Process-local read-only owner lookup. Mutable Agent execution state never
    # crosses this boundary; external callers receive only routing/ownership data.
    def agent_execution_owner(execution_id)
      key = execution_id.to_s
      @lifecycle_mutex.synchronize do
        state = @agent_executions[key]
        next nil unless state

        AgentExecutionOwner.new(
          execution_id: key.freeze,
          agent: state.agent,
          coordinator: state.coordinator,
          status: state.execution.status
        )
      end
    end

    # EventLoop-only accessors below form the live Agent execution authority.
    # Offload workers receive operation-specific immutable snapshots instead.
    # @api private
    def agent_execution_state(execution_id)
      assert_event_loop_thread!
      @agent_executions[execution_id.to_s]
    end

    # @api private
    def install_agent_execution(
      execution_id:,
      agent:,
      coordinator:,
      execution:,
      runtime_projection:,
      base_manifest:,
      invocation:,
      fsm_session_id:
    )
      assert_event_loop_thread!
      key = execution_id.to_s
      state = AgentExecutionState.new(
        execution_id: key.freeze,
        agent: agent,
        coordinator: coordinator,
        execution: execution,
        runtime_projection: runtime_projection,
        base_manifest: base_manifest,
        invocation: invocation,
        fsm_session_id: fsm_session_id&.to_s&.freeze
      )
      @lifecycle_mutex.synchronize do
        if @agent_executions.key?(key)
          raise Phronomy::Error, "Agent execution #{key.inspect} is already live"
        end
        @agent_executions[key] = state
      end
      state
    end

    # @api private
    def replace_agent_execution(
      execution_id,
      execution: UNSET,
      runtime_projection: UNSET,
      invocation: UNSET,
      fsm_session_id: UNSET
    )
      assert_event_loop_thread!
      key = execution_id.to_s
      @lifecycle_mutex.synchronize do
        current = @agent_executions.fetch(key) do
          raise Phronomy::Error, "Agent execution #{key.inspect} is not live"
        end
        updated = AgentExecutionState.new(
          execution_id: current.execution_id,
          agent: current.agent,
          coordinator: current.coordinator,
          execution: execution.equal?(UNSET) ? current.execution : execution,
          runtime_projection: runtime_projection.equal?(UNSET) ?
            current.runtime_projection : runtime_projection,
          base_manifest: current.base_manifest,
          invocation: invocation.equal?(UNSET) ? current.invocation : invocation,
          fsm_session_id: fsm_session_id.equal?(UNSET) ?
            current.fsm_session_id : fsm_session_id&.to_s&.freeze
        )
        @agent_executions[key] = updated
        updated
      end
    end

    # @api private
    def release_agent_execution(execution_id)
      assert_event_loop_thread!
      @lifecycle_mutex.synchronize do
        @agent_executions.delete(execution_id.to_s)
      end
    end

    # @api private
    def fsm_session_state(fsm_session_id)
      assert_event_loop_thread!
      @fsms[fsm_session_id.to_s]&.current_state
    end

    # Reserves one logical Workflow instance for one concrete FSMSession execution.
    # workflow_instance_id is durable Workflow identity; owner_fsm_session_id is the
    # Runtime-only identity of the invocation/resume that currently owns it.
    def admit_workflow(workflow_instance_id, owner_fsm_session_id:)
      key = workflow_instance_id.to_s
      owner = owner_fsm_session_id.to_s
      raise ArgumentError, "workflow_instance_id must not be empty" if key.empty?
      raise ArgumentError, "owner_fsm_session_id must not be empty" if owner.empty?

      @lifecycle_mutex.synchronize do
        ensure_accepting_registrations!
        current_owner = @workflow_admissions[key]
        if current_owner
          raise Phronomy::Error,
            "Workflow instance #{key.inspect} is already owned by " \
            "FSMSession #{current_owner.inspect}"
        end
        @workflow_admissions[key] = owner
      end
      true
    end

    def release_workflow(workflow_instance_id, owner_fsm_session_id:)
      key = workflow_instance_id.to_s
      owner = owner_fsm_session_id.to_s
      @lifecycle_mutex.synchronize do
        next false unless @workflow_admissions[key] == owner

        @workflow_admissions.delete(key)
        @idle_cond.broadcast if runtime_idle_locked?
        true
      end
    end

    def workflow_admission_owner(workflow_instance_id)
      @lifecycle_mutex.synchronize { @workflow_admissions[workflow_instance_id.to_s] }
    end

    def post_to_workflow(workflow_instance_id:, event:, payload: nil)
      queued_depth = nil
      posted_event = nil
      accepted = @lifecycle_mutex.synchronize do
        next false unless accepting_events?

        owner = @workflow_admissions[workflow_instance_id.to_s]
        next false unless owner
        next false unless @admitted_fsm_session_ids.include?(owner)

        posted_event = Phronomy::Event.new(
          type: event.to_sym,
          target_id: owner,
          payload: payload
        )
        queued_depth = enqueue([posted_event, monotonic_nanoseconds])
        true
      end
      return false unless accepted

      check_queue_backlog(queued_depth, posted_event)
      true
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
        complete_waiter(waiter, event.payload.fetch(:result))
      when :start
        session = event.payload.fetch(:session)
        waiter = event.payload[:completion]
        @fsms[session.id] = session
        @waiting[session.id] = waiter if waiter
        session.start
      when :agent_control, :agent_terminal_ready
        # :agent_terminal_ready is retained as an internal migration-compatible
        # dispatch name; ACS-11 emits the operation-neutral :agent_control event.
        cmd = event.payload.fetch(:command)
        cmd.coordinator.deliver_on_event_loop(cmd)
      when :workflow_persistence_ready
        cmd = event.payload.fetch(:command)
        cmd.runner.deliver_persistence_on_event_loop(cmd)
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
      @lifecycle_mutex.synchronize do
        @admitted_fsm_session_ids.clear
        @workflow_admissions.clear
        @agent_admissions.clear
        @agent_executions.clear
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
        @admitted_fsm_session_ids.clear
        @workflow_admissions.clear
        @agent_admissions.clear
        @agent_executions.clear
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
      @outstanding_sessions.zero? &&
        @workflow_admissions.empty? &&
        !agent_admission_transition_in_progress_locked?
    end

    def agent_admission_transition_in_progress_locked?
      @agent_admissions.values.any? do |admission|
        %i[admitting executing resuming terminalizing].include?(admission.state)
      end
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
        @workflow_admissions.clear
        @agent_admissions.clear
        @agent_executions.clear
        @thread = nil unless @thread&.alive?
        @idle_cond.broadcast
      end
      status
    end

    def complete_waiter(waiter, payload)
      return unless waiter

      if waiter.is_a?(Phronomy::Task)
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
      threshold = Phronomy.configuration.event_loop_starvation_threshold_seconds
      return unless threshold
      return unless lag_ns > (threshold * 1_000_000_000)

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
