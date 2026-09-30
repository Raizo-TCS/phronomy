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
      attr_reader :contents, :teams, :team_executions

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
