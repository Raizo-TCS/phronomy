# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent-owned admission, live execution state and physical quiescence.
    # The EventLoop remains the sole writer during execution.
    # @api private
    class ExecutionRegistry < Phronomy::ExecutionReceiver
      def self.existing_current
        ExecutionEnvironment.current.existing_registry
      end

      # Immutable Agent-owned value. The map containing these records is the
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

      # Agent-owned process-local top-level execution admission. This is
      # separate from AgentExecutionState because admission begins before the
      # durable AgentExecution exists. owner_token is coordination-only and is
      # never a semantic result-authority identifier.
      AgentAdmission = Data.define(:agent_id, :owner_token, :execution_id, :state)
      private_constant :AgentAdmission

      # The admission token is retained independently of the durable execution
      # ID, so an old recovery reference cannot release a replacement owner.
      TerminalOperationEntry = Data.define(
        :operation, :agent, :coordinator, :owner_token, :agent_id,
        :execution_id, :fsm_session_id
      )
      private_constant :TerminalOperationEntry

      UNSET = Object.new.freeze
      PhysicalCompletion = Data.define(:execution_id, :token)
      private_constant :UNSET, :PhysicalCompletion

      def initialize(channel:)
        super
        @agent_admissions = {}
        @agent_executions = {}
        @agent_completion_waiters = Hash.new { |hash, key| hash[key] = [] }
        @agent_inflight_work = Hash.new { |hash, key| hash[key] = {} }
        @agent_deferred_terminals = {}
        @terminal_operations = {}
      end

      def post(command, admission: false, completion: nil)
        post_message(command, admission: admission, completion: completion)
      end

      def deliver(command)
        assert_event_loop_thread!
        case command
        when PhysicalCompletion
          complete_agent_physical_work(command)
        when TerminalRecoveryOperation::Observe, TerminalRecoveryOperation::Ready
          command.operation.deliver(command)
        else
          command.coordinator.deliver_on_event_loop(command)
        end
      end

      # Called under the EventLoop lifecycle lock, including during shutdown.
      def idle?
        @agent_inflight_work.values.all?(&:empty?) &&
          @agent_deferred_terminals.empty? &&
          @terminal_operations.empty? &&
          !agent_admission_transition_in_progress_locked?
      end

      # A dispatcher failure runs this on EventLoop; normal teardown runs it only
      # after that thread has joined. Task callbacks run outside the lifecycle lock.
      def shutdown(error:)
        pending, retained = synchronize do
          waiters = @agent_completion_waiters.dup
          @agent_completion_waiters.clear
          @agent_inflight_work.delete_if { |id, _work| !@terminal_operations.key?(id) }
          @agent_deferred_terminals.delete_if { |id, _command| !@terminal_operations.key?(id) }
          @agent_admissions.delete_if { |_id, admission| !@terminal_operations.key?(admission.execution_id) }
          @agent_executions.delete_if { |id, _state| !@terminal_operations.key?(id) }
          [waiters, @terminal_operations.values.map(&:operation)]
        end

        failure = error || Phronomy::ExecutionRehydrationRequiredError.new(
          "Runtime terminated while Agent execution remained nonterminal; " \
          "process-local TaskResult handles are not rehydrated"
        )
        retained.each do |operation|
          waiters = pending.delete(operation.execution_id)
          operation.retain_original_waiters(Array(waiters))
          diagnostic = operation.shutdown(failure)
          settle_shutdown_waiters(waiters,
            diagnostic.is_a?(Exception) ? diagnostic : failure, finish: false)
        end
        pending.each_value { |waiters| settle_shutdown_waiters(waiters, failure) }
      end

      # Retain custody before a terminal worker can start. Live Agent mutation
      # remains on this receiver; workers may only record evidence in the owner.
      # @api private
      def retain_terminal_operation(operation)
        assert_event_loop_thread!
        key = operation.execution_id.to_s
        synchronize do
          state = @agent_executions[key]
          admission = @agent_admissions[operation.agent_id.to_s]
          unless state && state.agent.equal?(operation.agent) &&
              state.coordinator.equal?(operation.coordinator) &&
              state.execution.execution_revision == operation.expected_execution_revision &&
              state.fsm_session_id.to_s == operation.fsm_session_id.to_s &&
              admission&.execution_id == key && !@terminal_operations.key?(key)
            raise Phronomy::Error, "Agent terminal operation has no unique matching owner"
          end
          @terminal_operations[key] = TerminalOperationEntry.new(
            operation: operation, agent: state.agent, coordinator: state.coordinator,
            owner_token: admission.owner_token, agent_id: admission.agent_id,
            execution_id: key.freeze, fsm_session_id: state.fsm_session_id
          )
        end
        operation
      end

      # @api private
      def terminal_operation(execution_id)
        synchronize { @terminal_operations[execution_id.to_s]&.operation }
      end

      # The owner checks its expected pre-revision before applying, and may then
      # retry release at the applied post-revision. This predicate checks custody.
      # @api private
      def owns_terminal_operation?(operation)
        synchronize { owns_terminal_operation_locked?(operation) }
      end

      # Read-only lookup through the existing original Runtime, including after
      # stopped delivery. It never creates an owner or performs persistence I/O.
      # @api private
      def pending_agent_terminal_recovery(execution_id, agent:)
        entry = synchronize { @terminal_operations[execution_id.to_s] }
        entry.operation.recovery if entry&.agent&.equal?(agent) && entry.operation.pending?
      end

      # One atomic custody release after live application and physical quiescence.
      # @api private
      def release_terminal_operation(operation)
        assert_event_loop_thread!
        return false unless operation.release_permitted?

        released = synchronize do
          next false unless owns_terminal_operation_locked?(operation)
          key = operation.execution_id.to_s
          work = @agent_inflight_work.fetch(key, nil)
          next false if work && !work.empty?
          next false if @agent_deferred_terminals.key?(key)

          entry = @terminal_operations.delete(key)
          @agent_inflight_work.delete(key)
          @agent_executions.delete(key)
          @agent_admissions.delete(entry.agent_id)
          true
        end
        operation.released if released
        released
      end

      # Process-local read-only admission check used by destructive Agent lifecycle
      # operations. The mutable admission map itself remains Agent-owned.
      def agent_execution_admitted?(agent_id)
        synchronize { @agent_admissions.key?(agent_id.to_s) }
      end

      # Reserves the one top-level logical execution slot for agent_id before any
      # Persistence execution admission is attempted.
      # @api private
      def admit_agent_execution(agent_id, owner_token:)
        assert_event_loop_thread!
        key = agent_id.to_s
        raise ArgumentError, "agent_id must not be empty" if key.empty?
        raise ArgumentError, "owner_token is required" unless owner_token

        admit do
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
        synchronize do
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
      def mark_agent_execution_admission(agent_id, execution_id:, state:, expected_state: nil)
        assert_event_loop_thread!
        key = agent_id.to_s
        execution_key = execution_id.to_s
        next_state = state.to_sym
        unless %i[executing suspended resuming cancelling terminalizing recovery_required].include?(next_state)
          raise ArgumentError, "unsupported Agent admission state: #{next_state.inspect}"
        end

        synchronize do
          current = @agent_admissions.fetch(key) do
            raise Phronomy::Error, "Agent #{key.inspect} has no Runtime admission"
          end
          unless current.execution_id.to_s == execution_key
            raise Phronomy::Error, "stale Agent admission state update for #{key.inspect}"
          end
          if expected_state && current.state != expected_state
            raise Phronomy::AgentBusyError,
              "Agent #{key.inspect} is #{current.state}, expected #{expected_state}"
          end
          @agent_admissions[key] = AgentAdmission.new(
            agent_id: current.agent_id,
            owner_token: current.owner_token,
            execution_id: current.execution_id,
            state: next_state
          )
        end
        true
      end

      # @api private
      def mark_agent_admission_recovery_required(agent_id, owner_token:)
        assert_event_loop_thread!
        key = agent_id.to_s
        synchronize do
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
        end
        true
      end

      # Owner-aware release. Pre-durable failures release by owner_token; durable
      # terminal outcomes release by execution_id.
      # @api private
      def release_agent_execution_admission(agent_id, owner_token: nil, execution_id: nil)
        assert_event_loop_thread!
        key = agent_id.to_s
        synchronize do
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
          next false if @terminal_operations.key?(current.execution_id)

          @agent_admissions.delete(key)
          true
        end
      end

      # Process-local read-only owner lookup. Mutable Agent execution state never
      # crosses this boundary; external callers receive only routing/ownership data.
      def agent_execution_owner(execution_id)
        key = execution_id.to_s
        synchronize do
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
        synchronize do
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
        synchronize do
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

      # Registers a caller-facing TaskResult that observes the authoritative terminal
      # outcome of one logical Agent execution. Waiters are Runtime-only and are
      # never persisted or rehydrated.
      # @api private
      def register_agent_completion_waiter(execution_id, task)
        assert_event_loop_thread!
        unless task.is_a?(Phronomy::TaskResult)
          raise ArgumentError, "Agent completion waiter must be a Phronomy::TaskResult"
        end

        key = execution_id.to_s
        synchronize do
          waiters = @agent_completion_waiters[key]
          waiters << task unless waiters.include?(task)
        end
        task
      end

      # Atomically detaches all process-local completion waiters at authoritative
      # terminal delivery. A fallback TaskResult is included for pre-install terminal
      # paths that never acquired a live execution directory entry.
      # @api private
      def take_agent_completion_waiters(execution_id, fallback: nil)
        assert_event_loop_thread!
        key = execution_id.to_s
        synchronize do
          waiters = @agent_completion_waiters.delete(key) || []
          waiters << fallback if fallback && !waiters.include?(fallback)
          waiters
        end
      end

      # Registers one execution-owned asynchronous operation for physical
      # quiescence supervision. OffloadPool tasks expose a private physical
      # completion signal; custom asynchronous handles are required to make their
      # ordinary completion mean that no residual execution-affecting work remains.
      # @api private
      def supervise_agent_operation(execution_id, operation)
        assert_event_loop_thread!
        key = execution_id.to_s
        unless operation.respond_to?(:on_complete)
          raise ArgumentError, "supervised operation must expose on_complete"
        end

        physically_done = if operation.respond_to?(:physical_complete?)
          operation.physical_complete?
        elsif operation.respond_to?(:done?)
          operation.done?
        else
          false
        end
        return operation if physically_done

        token = Object.new.freeze
        synchronize do
          unless @agent_executions.key?(key)
            raise Phronomy::Error, "Agent execution #{key.inspect} is not live"
          end
          @agent_inflight_work[key][token] = true
        end

        callback = lambda do
          accepted = post_message(PhysicalCompletion.new(execution_id: key, token: token))
          unless accepted
            Phronomy::RuntimeSettings.current.logger&.warn(
              "[Phronomy] EventLoop rejected physical-completion delivery for #{key}"
            )
          end
        end

        if operation.respond_to?(:on_physical_complete)
          operation.on_physical_complete(&callback)
        else
          operation.on_complete { |_value, _error| callback.call }
        end
        operation
      end

      # @api private
      def agent_execution_quiescent?(execution_id)
        assert_event_loop_thread!
        key = execution_id.to_s
        synchronize do
          work = @agent_inflight_work.fetch(key, nil)
          work.nil? || work.empty?
        end
      end

      # Holds exactly one terminal continuation while cancellation/deadline has
      # revoked result authority but execution-owned physical work is still live.
      # @api private
      def defer_agent_terminal_until_quiescent(execution_id, command)
        assert_event_loop_thread!
        key = execution_id.to_s
        synchronize do
          if @agent_deferred_terminals.key?(key)
            raise Phronomy::Error, "Agent execution #{key.inspect} already has a deferred terminal"
          end
          @agent_deferred_terminals[key] = command
        end
        true
      end

      # @api private
      def agent_inflight_work_count(execution_id)
        key = execution_id.to_s
        synchronize do
          (@agent_inflight_work.fetch(key, nil) || {}).size
        end
      end

      # @api private
      def release_agent_execution(execution_id)
        assert_event_loop_thread!
        key = execution_id.to_s
        synchronize do
          if @terminal_operations.key?(key)
            raise Phronomy::Error, "Agent execution #{key.inspect} requires terminal operation release"
          end
          work = @agent_inflight_work.fetch(key, nil)
          unless work.nil? || work.empty?
            raise Phronomy::Error,
              "cannot release non-quiescent Agent execution #{key.inspect}"
          end
          if @agent_deferred_terminals.key?(key)
            raise Phronomy::Error,
              "cannot release Agent execution #{key.inspect} with deferred terminal work"
          end
          @agent_inflight_work.delete(key)
          @agent_executions.delete(key)
        end
      end

      private

      def owns_terminal_operation_locked?(operation)
        entry = @terminal_operations[operation.execution_id.to_s]
        return false unless entry&.operation&.equal?(operation)
        admission = @agent_admissions[entry.agent_id]
        state = @agent_executions[entry.execution_id]
        admission&.owner_token&.equal?(entry.owner_token) &&
          admission.execution_id == entry.execution_id &&
          state&.agent&.equal?(entry.agent) && state.coordinator.equal?(entry.coordinator) &&
          state.fsm_session_id.to_s == entry.fsm_session_id.to_s
      end

      def settle_shutdown_waiters(waiters, error, finish: true)
        Array(waiters).each do |waiter|
          waiter.finish_operation! if finish && waiter.respond_to?(:finish_operation!)
          waiter.fail(error)
        end
      end

      def complete_agent_physical_work(payload)
        key = payload.execution_id.to_s
        token = payload.token
        deferred = synchronize do
          work = @agent_inflight_work.fetch(key, nil)
          next nil unless work&.delete(token)

          if work.empty?
            @agent_inflight_work.delete(key)
            command = @agent_deferred_terminals.delete(key)
            command
          end
        end
        deferred&.coordinator&.deliver_on_event_loop(deferred)
        true
      end

      def agent_admission_transition_in_progress_locked?
        @agent_admissions.values.any? do |admission|
          %i[admitting executing resuming cancelling terminalizing].include?(admission.state)
        end
      end
    end
  end
end
