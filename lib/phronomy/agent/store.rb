# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent-owned durable operations and observations. An injected record
    # adapter implements storage; this framework never selects a DB or codec.
    # @api public
    class Store
      # Provider-ordered authorized calls, with no internal execution metadata.
      AuthorizedOperation = Data.define(:invocation_id, :name, :arguments)

      attr_reader :coordinator

      # Record protocol for Agent-owned framework operations only.
      # @api private
      attr_reader :contents, :agents, :journals, :executions, :handoff_states

      def initialize(coordinator:, records:)
        @coordinator, @record_adapter = coordinator, records
        @records = coordinator.bind(records)
        @contents = @records.contents
        @agents = @records.agents
        @journals = @records.journals
        @executions = @records.executions
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

      # Authoritative presence only. Failed reads propagate, never mean absent.
      def exist?(agent_id)
        assert_observation_thread!
        agents.load(agent_id)
        true
      rescue Phronomy::Persistence::NotFoundError
        false
      end

      # Validate the exact requested call and project its authorized batch in
      # Provider order from one execution snapshot in the caller's transaction.
      # The receiving domain owns application and replay of these operations.
      def authorized_operations(scope, agent_id:, execution_id:, invocation_id:, name:, arguments:, names:)
        participate(scope) do |records|
          execution = records.executions.load(execution_id)
          unless execution.agent_id == agent_id
            raise Phronomy::Persistence::StateConflictError, "Authorized operation owner mismatch"
          end
          batch = Array(execution.metadata[ExecutionMetadata::TOOL_BATCH_METADATA_KEY])
          requested = batch.find { |entry| entry.fetch("tool_invocation_id") == invocation_id }
          unless names.include?(name) && requested && requested.fetch("status") == "authorized" &&
              requested.fetch("tool_name") == name && requested.fetch("arguments").compact == arguments
            raise Phronomy::Persistence::StateConflictError, "Operation #{invocation_id} is not the authorized call"
          end
          batch.filter_map do |entry|
            next unless entry.fetch("status") == "authorized" && names.include?(entry.fetch("tool_name"))
            AuthorizedOperation.new(
              invocation_id: Phronomy::Values::Immutable.copy(entry.fetch("tool_invocation_id")),
              name: Phronomy::Values::Immutable.copy(entry.fetch("tool_name")),
              arguments: Phronomy::Values::Immutable.copy(entry.fetch("arguments").compact)
            )
          end.freeze
        end
      end

      def result(execution_id)
        assert_observation_thread!
        execution = executions.load(execution_id)
        {
          execution_id: execution.execution_id, agent_id: execution.agent_id,
          status: execution.status, phase: execution.phase,
          result_ref: execution.result_ref, error_ref: execution.error_ref,
          result: execution.result_ref && contents.fetch_text(execution.result_ref),
          error: execution.error_ref && contents.fetch_json(execution.error_ref)
        }.then { |value| Phronomy::Values::Immutable.copy(value) }
      end

      def handoff_result(execution_id, main_agent_id: nil)
        assert_observation_thread!
        anchor = main_agent_id&.to_s
        seen = {}
        current = execution_id.to_s
        reserved_agent_id = nil
        loop do
          raise Phronomy::Persistence::SerializationError, "Cyclic durable Handoff chain" if seen[current]
          seen[current] = true
          begin
            execution = executions.load(current)
          rescue Phronomy::Persistence::NotFoundError
            routing = handoff_states.load(anchor)
            if routing && Array(routing.metadata["cancelled_execution_ids"]).include?(current)
              return {execution_id: current, agent_id: reserved_agent_id, status: :cancelled, result: nil, error: nil}.freeze
            end
            if reserved_agent_id && routing && routing.phase != "stable" && routing.pending_target_execution_id == current
              return {execution_id: current, agent_id: reserved_agent_id, status: :active,
                      phase: :target_pending, reserved: true, result: nil, error: nil}.freeze
            end
            raise
          end
          anchor ||= execution.metadata.dig("coordination", "main_agent_id")
          unless anchor && execution.metadata.dig("coordination", "main_agent_id") == anchor
            raise Phronomy::Persistence::StateConflictError, "Execution does not belong to this Handoff anchor"
          end
          return result(current) unless execution.status == :handed_off
          reserved_agent_id = execution.metadata.fetch("handoff_target_agent_id")
          current = execution.metadata.fetch("handoff_target_execution_id")
        end
      end

      def runs(agent_id, after: nil, limit: 100)
        assert_observation_thread!
        executions.list(agent_id, after: after, limit: limit)
      end

      # Agent's snapshot fence, independent of any physical schema.
      def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
        @records.assert_agent_watermark!(agent_id: agent_id, agent_revision: agent_revision, journal_position: journal_position)
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
