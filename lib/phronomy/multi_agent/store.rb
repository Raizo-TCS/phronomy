# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # MultiAgent-owned durable operations and observations. An injected record
    # adapter implements storage; this framework never selects a DB or codec.
    # @api public
    class Store
      attr_reader :coordinator, :agent_store

      # Record protocol for MultiAgent-owned framework operations only.
      # @api private
      attr_reader :contents, :teams, :team_executions, :handoff_states

      def initialize(coordinator:, records:, agent_store:)
        @coordinator, @record_adapter = coordinator, records

        unless agent_store.coordinator.equal?(coordinator)
          raise Phronomy::Persistence::TransactionError, "Team and Agent stores must share one Persistence coordinator"
        end
        @agent_store = agent_store
        @records = coordinator.bind(records)
        @contents = @records.contents
        @teams = @records.teams
        @team_executions = @records.team_executions
        @handoff_states = @records.handoff_states
      end

      # A domain operation owns this short transaction. A coordinating parent
      # can instead call participate with its existing shared scope.
      def transaction
        coordinator.atomic do |scope|
          participate(scope) { |records| yield records, scope }
        end
      end

      def participate(scope, &operation)
        scope.participate(persistence: coordinator, adapter: @record_adapter, &operation)
      end

      def handoff_leaf(execution_id, main_agent_id:, scope: nil)
        return coordinator.atomic { |current| handoff_leaf(execution_id, main_agent_id: main_agent_id, scope: current) } unless scope
        routing = participate(scope) { |records| records.handoff_states.load(main_agent_id) }
        raise Phronomy::Persistence::NotFoundError, "Handoff history is absent" unless routing
        identity = agent_store.execution_identity(execution_id, scope: scope)
        unless identity.correlation == {"kind" => "handoff", "main_agent_id" => main_agent_id}
          raise Phronomy::Persistence::StateConflictError, "Execution does not belong to this Handoff anchor"
        end
        seen = {}
        loop do
          raise Phronomy::Persistence::SerializationError, "Cyclic Handoff chain" if seen[identity.execution_id]
          seen[identity.execution_id] = true
          observed = agent_store.observe_execution(agent_id: identity.agent_id, execution_id: identity.execution_id, scope: scope)
          return observed unless observed.status == :handed_off
          receipt = observed.transfer_receipt
          unless receipt && receipt.fetch("owner_key") == "handoff:#{main_agent_id}"
            raise Phronomy::Persistence::SerializationError, "Invalid transfer receipt"
          end
          identity = Phronomy::Agent::ReservedExecution.new(agent_id: receipt.fetch("target_agent_id"), execution_id: receipt.fetch("target_execution_id"))
        end
      end

      def handoff_result(execution_id, main_agent_id:)
        assert_observation_thread!
        transaction do |records, scope|
          leaf = handoff_leaf(execution_id, main_agent_id: main_agent_id, scope: scope)
          next leaf.to_result unless leaf.absent?
          routing = records.handoff_states.load(main_agent_id)
          if Array(routing.metadata["cancelled_execution_ids"]).include?(leaf.execution_id)
            leaf.to_result.merge(status: :cancelled).freeze
          elsif routing.phase != "stable" && routing.pending_target_execution_id == leaf.execution_id
            leaf.to_result.merge(status: :active, reserved: true).freeze
          else
            raise Phronomy::Persistence::NotFoundError, "Reserved Handoff execution is absent"
          end
        end
      end

      def forget_subagents(agent_id:, execution_id:)
        transaction do |records, scope|
          extension = agent_store.execution_extension(agent_id: agent_id, execution_id: execution_id,
            binding_key: DurableSubagentCoordinator::BINDING_KEY, scope: scope)
          raise Phronomy::Persistence::NotFoundError, "Subagent history is absent" unless extension&.state_ref
          snapshot = records.contents.fetch_json(extension.state_ref)
          children = snapshot.fetch("children")
          ids = ([agent_id] + children.map { |child| child.fetch("agent_id") }).uniq.sort.select { |id| agent_store.exist?(id) }
          agent_store.guard_agents(scope, agent_ids: ids)
          parent = agent_store.observe_execution(agent_id: agent_id, execution_id: execution_id, scope: scope)
          raise Phronomy::AgentBusyError, "Subagent history retains unfinished parent" unless parent.terminal?
          children.each do |child|
            observed = agent_store.observe_execution(agent_id: child.fetch("agent_id"), execution_id: child.fetch("execution_id"), scope: scope)
            if !observed.terminal? && !(observed.absent? && snapshot["cancel_requested"])
              raise Phronomy::AgentBusyError, "Subagent history retains unfinished child"
            end
          end
          agent_store.remove_execution_extension(agent_id: agent_id, execution_id: execution_id,
            binding_key: DurableSubagentCoordinator::BINDING_KEY, scope: scope)
          ids.each { |id| agent_store.release_retention(agent_id: id, owner_key: "subagent:#{execution_id}", scope: scope) }
        end
        true
      end

      def forget_handoff(main_agent_id)
        transaction do |records, scope|
          routing = records.handoff_states.load_locked(main_agent_id)
          raise Phronomy::Persistence::NotFoundError, "Handoff history is absent" unless routing
          ids = (Array(routing.metadata["retained_agent_ids"]) + [main_agent_id, routing.active_agent_id]).uniq.sort
          agent_store.guard_agents(scope, agent_ids: ids)
          unless routing.phase == "stable" && ids.all? { |id| agent_store.active_executions(agent_id: id, scope: scope).empty? }
            raise Phronomy::AgentBusyError, "Handoff history retains unfinished work"
          end
          records.handoff_states.delete(main_agent_id, expected_revision: routing.handoff_revision)
          ids.each { |id| agent_store.release_retention(agent_id: id, owner_key: "handoff:#{main_agent_id}", scope: scope) }
        end
        true
      end

      def result(team_execution_id)
        assert_observation_thread!
        execution = team_executions.load(team_execution_id)
        {
          team_execution_id: execution.team_execution_id, team_id: execution.team_id,
          status: execution.status, phase: execution.phase,
          result_ref: execution.result_ref, error_ref: execution.error_ref,
          result: execution.result_ref && contents.fetch_json(execution.result_ref),
          error: execution.error_ref && contents.fetch_json(execution.error_ref)
        }.then { |value| Phronomy::Values::Immutable.copy(value) }
      end

      def runs(team_id, after: nil, limit: 100)
        assert_observation_thread!
        team_executions.list(team_id, after: after, limit: limit)
      end

      private

      def assert_observation_thread!
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError, "Durable observation cannot block EventLoop"
        end
      end
    end
  end
end
