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
      CustodyQuery = Data.define(:agent_id, :execution_id, :environment, :completion)
      private_constant :UNSET, :PhysicalCompletion, :CustodyQuery

      def initialize(channel:)
        super
        @agent_admissions = {}
        @agent_executions = {}
        @agent_completion_waiters = Hash.new { |hash, key| hash[key] = [] }
        @agent_inflight_work = Hash.new { |hash, key| hash[key] = {} }
        @agent_deferred_terminals = {}
        @terminal_operations = {}
        @approval_operations = {}
        @dispatch_operations = {}
        @initial_preparations = {}
      end

      def post(command, admission: false, completion: nil)
        post_message(command, admission: admission, completion: completion)
      end

      def deliver(command)
        assert_event_loop_thread!
        case command
        when PhysicalCompletion
          complete_agent_physical_work(command)
        when CustodyQuery
          deliver_custody_query(command)
        when OutcomeRecoveryOperation::Observe, OutcomeRecoveryOperation::Ready,
            ApprovalRecoveryOperation::Observe, ApprovalRecoveryOperation::Ready,
            DispatchRecoveryOperation::Observe, DispatchRecoveryOperation::Ready,
            InitialPreparationRecoveryOperation::Observe, InitialPreparationRecoveryOperation::Ready
          command.operation.deliver(command)
        else
          command.coordinator.deliver_on_event_loop(command)
        end
      end

      # Queue behind ordinary delivery so settling a waiter before owner release
      # does not expose the intermediate state to a coordinating host caller.
      # @api private
      def observe_execution_custody(agent_id:, execution_id:, environment:)
        completion = Phronomy::TaskResult.deferred(name: "agent-custody:#{execution_id}")
        query = CustodyQuery.new(agent_id: agent_id.to_s.dup.freeze,
          execution_id: execution_id.to_s.dup.freeze, environment: environment, completion: completion)
        unless post(query, completion: completion)
          completion.fail(Phronomy::RuntimeShutdownError.new("Agent custody observation was rejected"))
        end
        completion
      rescue => error
        completion&.fail(error)
        completion || raise
      end

      private def deliver_custody_query(query)
        query.environment.assert_custody_query_available!
        pending = synchronize do
          key = query.execution_id
          admission = @agent_admissions[query.agent_id]
          # Nil admission identity is conservative. Same-ID foreign entries are
          # also ambiguous custody, never proof that this Agent owns their work.
          !!((admission && (admission.execution_id.nil? || admission.execution_id == key)) ||
            @initial_preparations.values.any? { |operation| operation.execution_id == key } ||
            @agent_executions.key?(key) || @terminal_operations.key?(key) ||
            @approval_operations.key?(key) || @dispatch_operations.key?(key) ||
            @agent_inflight_work.fetch(key, nil)&.any? || @agent_deferred_terminals.key?(key) ||
            @agent_completion_waiters.fetch(key, nil)&.any?)
        end
        query.completion.complete(pending)
      rescue => error
        query.completion.fail(error)
      end

      # Called under the EventLoop lifecycle lock, including during shutdown.
      def idle?
        @agent_inflight_work.values.all?(&:empty?) &&
          @agent_deferred_terminals.empty? &&
          @terminal_operations.empty? && @approval_operations.empty? && @dispatch_operations.empty? &&
          @initial_preparations.empty? && !agent_admission_transition_in_progress_locked?
      end

      # A dispatcher failure runs this on EventLoop; normal teardown runs it only
      # after that thread has joined. Task callbacks run outside the lifecycle lock.
      def shutdown(error:)
        pending, retained = synchronize do
          retained_ids = @terminal_operations.keys | @approval_operations.keys | @dispatch_operations.keys |
            @initial_preparations.values.map(&:execution_id)
          waiters = @agent_completion_waiters.dup
          @agent_completion_waiters.clear
          @agent_inflight_work.delete_if { |id, _work| !retained_ids.include?(id) }
          @agent_deferred_terminals.delete_if { |id, _command| !retained_ids.include?(id) }
          @agent_admissions.delete_if { |id, admission| !@initial_preparations.key?(id) && !retained_ids.include?(admission.execution_id) }
          @agent_executions.delete_if { |id, _state| !retained_ids.include?(id) }
          [waiters, (@terminal_operations.values + @approval_operations.values + @dispatch_operations.values).map(&:operation) + @initial_preparations.values]
        end

        failure = error || Phronomy::ExecutionRehydrationRequiredError.new(
          "Runtime terminated while Agent execution remained nonterminal; " \
          "process-local TaskResult handles are not rehydrated"
        )
        retained.each do |operation|
          waiters = pending.delete(operation.execution_id)
          operation.retain_original_waiters(Array(waiters))
          diagnostic = operation.shutdown(failure)
          fail_shutdown_waiters(waiters,
            diagnostic.is_a?(Exception) ? diagnostic : failure)
        end
        pending.each_value { |waiters| fail_shutdown_waiters(waiters, failure) }
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
        entry.operation.recovery if entry&.agent&.equal?(agent) &&
          entry.operation.recovery_kind == :terminal && entry.operation.pending?
      end

      def pending_agent_outcome_recovery(execution_id, agent:)
        entry = synchronize { @terminal_operations[execution_id.to_s] }
        entry.operation.recovery if entry&.agent&.equal?(agent) &&
          entry.operation.recovery_kind == :outcome && entry.operation.pending?
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
          next false if @agent_deferred_terminals.key?(key) || @approval_operations.key?(key) || @dispatch_operations.key?(key)

          entry = @terminal_operations.delete(key)
          @agent_inflight_work.delete(key)
          @agent_executions.delete(key)
          @agent_admissions.delete(entry.agent_id)
          true
        end
        operation.released if released
        released
      end

      # A committed approval wait resolves only the save owner. The logical
      # execution, admission and cancellation responsibility remain suspended.
      def resolve_outcome_approval_wait(operation)
        assert_event_loop_thread!
        return false unless operation.release_permitted?

        released = synchronize do
          next false unless owns_terminal_operation_locked?(operation)
          key = operation.execution_id.to_s
          state = @agent_executions.fetch(key)
          next false unless state.execution.status == :suspended
          work = @agent_inflight_work.fetch(key, nil)
          next false if work && !work.empty?
          next false if @agent_deferred_terminals.key?(key) || @approval_operations.key?(key) || @dispatch_operations.key?(key)

          entry = @terminal_operations.delete(key)
          @agent_executions[key] = state.with(fsm_session_id: nil)
          @agent_admissions[entry.agent_id] = @agent_admissions.fetch(entry.agent_id).with(state: :suspended)
          true
        end
        operation.released if released
        released
      end

      # Approval decision custody ends at restored waiting or accepted continuation;
      # it never releases the Agent execution's admission.
      def retain_approval_operation(operation)
        assert_event_loop_thread!
        key = operation.execution_id.to_s
        synchronize do
          state = @agent_executions[key]
          admission = @agent_admissions[operation.agent_id.to_s]
          unless state && state.agent.equal?(operation.agent) && state.coordinator.equal?(operation.coordinator) &&
              state.execution.execution_revision == operation.command.expected_execution_revision &&
              state.invocation.equal?(operation.invocation) && state.fsm_session_id.nil? &&
              admission&.execution_id == key && !@approval_operations.key?(key)
            raise Phronomy::Error, "Agent approval decision has no unique matching owner"
          end
          @approval_operations[key] = TerminalOperationEntry.new(operation: operation,
            agent: state.agent, coordinator: state.coordinator, owner_token: admission.owner_token,
            agent_id: admission.agent_id, execution_id: key.freeze, fsm_session_id: nil)
        end
        operation
      end

      def approval_operation(execution_id)
        synchronize { @approval_operations[execution_id.to_s]&.operation }
      end

      def owns_approval_operation?(operation)
        synchronize { owns_approval_operation_locked?(operation) }
      end

      def pending_agent_approval_recovery(execution_id, agent:)
        entry = synchronize { @approval_operations[execution_id.to_s] }
        entry.operation.recovery if entry&.agent&.equal?(agent) && entry.operation.pending?
      end

      def resolve_approval_operation(operation)
        assert_event_loop_thread!
        return false unless operation.resolution_permitted?
        synchronize do
          next false unless owns_approval_operation_locked?(operation)
          @approval_operations.delete(operation.execution_id.to_s)
          operation.resolution_released!
          true
        end
      end

      # A dispatch barrier owns the captured preparation until it hands the same
      # invocation onward. Resolving it never releases execution admission.
      def retain_dispatch_operation(operation)
        assert_event_loop_thread!
        key = operation.execution_id.to_s
        synchronize do
          state = @agent_executions[key]
          admission = @agent_admissions[operation.agent_id.to_s]
          unless state && state.agent.equal?(operation.agent) && state.coordinator.equal?(operation.coordinator) &&
              state.execution.execution_revision == operation.command.expected_execution_revision &&
              state.invocation.equal?(operation.invocation) &&
              state.fsm_session_id.to_s == operation.command.fsm_session_id.to_s &&
              admission&.execution_id == key && !@dispatch_operations.key?(key)
            raise Phronomy::Error, "Agent dispatch preparation has no unique matching owner"
          end
          @dispatch_operations[key] = TerminalOperationEntry.new(operation: operation,
            agent: state.agent, coordinator: state.coordinator, owner_token: admission.owner_token,
            agent_id: admission.agent_id, execution_id: key.freeze, fsm_session_id: state.fsm_session_id)
        end
        operation
      end

      def dispatch_operation(execution_id)
        synchronize { @dispatch_operations[execution_id.to_s]&.operation }
      end

      def owns_dispatch_operation?(operation)
        synchronize { owns_dispatch_operation_locked?(operation) }
      end

      def pending_agent_dispatch_recovery(execution_id, agent:)
        entry = synchronize { @dispatch_operations[execution_id.to_s] }
        entry.operation.recovery if entry&.agent&.equal?(agent) && entry.operation.pending?
      end

      def resolve_dispatch_operation(operation)
        assert_event_loop_thread!
        return false unless operation.resolution_permitted?
        synchronize do
          next false unless owns_dispatch_operation_locked?(operation)
          @dispatch_operations.delete(operation.execution_id.to_s)
          operation.resolution_released!
          true
        end
      end

      def retain_initial_preparation(operation)
        assert_event_loop_thread!
        synchronize do
          admission = @agent_admissions[operation.agent_id]
          unless admission&.owner_token&.equal?(operation.request.admission_token) &&
              admission.execution_id.nil? && !@initial_preparations.key?(operation.agent_id)
            raise Phronomy::Error, "Initial preparation has no unique original admission"
          end
          @initial_preparations[operation.agent_id] = operation
        end
        operation
      end

      def owns_initial_preparation?(operation)
        synchronize { owns_initial_preparation_locked?(operation) }
      end

      def bind_initial_preparation(operation)
        assert_event_loop_thread!
        synchronize do
          unless owns_initial_preparation_locked?(operation)
            raise Phronomy::Error, "Initial preparation lost its original admission token"
          end
          current = @agent_admissions.fetch(operation.agent_id)
          @agent_admissions[operation.agent_id] = current.with(execution_id: operation.execution_id, state: :executing)
        end
      end

      # The caller has positively established that the cached session was never
      # admitted. Remove only this owner's exact, physically quiet projection.
      def discard_initial_projection(operation)
        assert_event_loop_thread!
        synchronize do
          return false unless owns_initial_preparation_locked?(operation)
          state = @agent_executions[operation.execution_id]
          return true unless state
          session = operation.initial_session
          unless session && state.agent.equal?(operation.agent) && state.coordinator.equal?(operation.coordinator) &&
              state.fsm_session_id == session.id && state.invocation.equal?(session.context) &&
              @agent_inflight_work[operation.execution_id].empty? && !@agent_deferred_terminals.key?(operation.execution_id)
            return false
          end
          @agent_executions.delete(operation.execution_id)
          true
        end
      end

      def pending_initial_preparation_recovery(agent:)
        operation = synchronize { @initial_preparations[agent.agent_id] }
        operation.recovery if operation&.belongs_to?(agent) && operation.pending?
      end

      # Transfer only the initial index. The exact admission token and any
      # live state/waiters remain owned by the existing terminal protocol.
      def transfer_initial_terminal_custody(operation, custody)
        assert_event_loop_thread!
        synchronize do
          next false unless owns_initial_preparation_locked?(operation)
          admission = @agent_admissions.fetch(operation.agent_id)
          command = custody.operation
          next false unless custody.coordinator.equal?(operation.coordinator) &&
            command.execution_id == operation.execution_id && command.execution.agent_id == operation.agent_id &&
            admission.execution_id == operation.execution_id && %i[terminalizing recovery_required].include?(admission.state)
          accepted = if custody.retained_owner
            @terminal_operations[operation.execution_id]&.operation.equal?(custody.retained_owner)
          else
            custody.task.is_a?(Phronomy::TaskResult)
          end
          next false unless accepted
          @initial_preparations.delete(operation.agent_id)
          true
        end
      end

      def resolve_initial_preparation(operation, state:)
        assert_event_loop_thread!
        return false unless operation.resolution_permitted?
        synchronize do
          next false unless owns_initial_preparation_locked?(operation)
          admission = @agent_admissions.fetch(operation.agent_id)
          if state == :resumed
            next false unless admission.execution_id == operation.execution_id && @agent_executions.key?(operation.execution_id)
          else
            next false if @agent_executions.key?(operation.execution_id)
            @agent_admissions.delete(operation.agent_id)
          end
          @initial_preparations.delete(operation.agent_id)
          operation.resolution_released!
          true
        end
      end

      private def owns_initial_preparation_locked?(operation)
        admission = @agent_admissions[operation.agent_id]
        @initial_preparations[operation.agent_id].equal?(operation) &&
          admission&.owner_token&.equal?(operation.request.admission_token) &&
          (admission.execution_id.nil? || admission.execution_id == operation.execution_id)
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
          next false if @initial_preparations.key?(key)
          next false if @terminal_operations.key?(current.execution_id) || @approval_operations.key?(current.execution_id) ||
            @dispatch_operations.key?(current.execution_id)

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

      # Snapshot only: observation failure does not remove job-completion leases.
      def agent_completion_waiters(execution_id)
        synchronize { @agent_completion_waiters.fetch(execution_id.to_s, []).dup.freeze }
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
          if @terminal_operations.key?(key) || @approval_operations.key?(key) || @dispatch_operations.key?(key)
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

      def owns_dispatch_operation_locked?(operation)
        entry = @dispatch_operations[operation.execution_id.to_s]
        return false unless entry&.operation&.equal?(operation)
        admission = @agent_admissions[entry.agent_id]
        state = @agent_executions[entry.execution_id]
        admission&.owner_token&.equal?(entry.owner_token) && admission.execution_id == entry.execution_id &&
          state&.agent&.equal?(entry.agent) && state.coordinator.equal?(entry.coordinator) &&
          state.invocation.equal?(operation.invocation) && state.fsm_session_id.to_s == entry.fsm_session_id.to_s
      end

      def owns_approval_operation_locked?(operation)
        entry = @approval_operations[operation.execution_id.to_s]
        return false unless entry&.operation&.equal?(operation)
        admission = @agent_admissions[entry.agent_id]
        state = @agent_executions[entry.execution_id]
        admission&.owner_token&.equal?(entry.owner_token) && admission.execution_id == entry.execution_id &&
          state&.agent&.equal?(entry.agent) && state.coordinator.equal?(entry.coordinator) &&
          state.invocation.equal?(operation.invocation)
      end

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

      # Stopped observation delivery is not domain-operation completion. Only a
      # retained terminal owner with known quiescence may acknowledge its work;
      # ordinary suspended executions keep their existing physical boundary.
      def fail_shutdown_waiters(waiters, error)
        Array(waiters).each { |waiter| waiter.fail(error) }
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
