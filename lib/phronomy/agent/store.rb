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
      attr_reader :contents, :agents, :journals, :executions, :retentions

      def initialize(coordinator:, records:)
        @coordinator, @record_adapter = coordinator, records
        @records = coordinator.bind(records)
        @contents = @records.contents
        @agents = @records.agents
        @journals = @records.journals
        @executions = @records.executions
        @retentions = @records.retentions
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
              requested.fetch("tool_name") == name && authorized_argument_values(requested) == arguments
            raise Phronomy::Persistence::StateConflictError, "Operation #{invocation_id} is not the authorized call"
          end
          batch.filter_map do |entry|
            next unless entry.fetch("status") == "authorized" && names.include?(entry.fetch("tool_name"))
            AuthorizedOperation.new(
              invocation_id: Phronomy::Values::Immutable.copy(entry.fetch("tool_invocation_id")),
              name: Phronomy::Values::Immutable.copy(entry.fetch("tool_name")),
              arguments: Phronomy::Values::Immutable.copy(authorized_argument_values(entry))
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

      # Exact, immutable observation. Only authoritative NotFound means absent.
      def observe_execution(agent_id:, execution_id:, scope: nil)
        with_scope(scope) do |records|
          begin
            execution = records.executions.load(execution_id)
          rescue Phronomy::Persistence::NotFoundError
            next ExecutionObservation.new(agent_id: agent_id, execution_id: execution_id,
              status: :absent, result: nil, error: nil, reservation: nil,
              transfer_receipt: nil, cancellation_requested: false)
          end
          assert_execution_owner!(execution, agent_id)
          ExecutionObservation.new(agent_id: execution.agent_id, execution_id: execution.execution_id,
            status: execution.status,
            result: execution.result_ref && records.contents.fetch_text(execution.result_ref),
            error: execution.error_ref && Phronomy::Values::Immutable.copy(records.contents.fetch_json(execution.error_ref)),
            reservation: execution.metadata["reservation"] && ReservedExecution.new(agent_id: agent_id,
              execution_id: execution_id, correlation: execution.metadata["reservation"]),
            transfer_receipt: Phronomy::Values::Immutable.copy(execution.metadata["transfer_receipt"]),
            cancellation_requested: records.cancellations.requested?(agent_id, execution_id) || execution.metadata["cancellation_requested"] == true)
        end
      end

      def active_executions(agent_id:, scope: nil)
        with_scope(scope) do |records|
          records.executions.list_active(agent_id).map do |execution|
            observe_execution(agent_id: agent_id, execution_id: execution.execution_id, scope: scope)
          end.freeze
        end
      end

      def definition(agent_id:, scope: nil)
        with_scope(scope) do |records|
          root = records.agents.load(agent_id)
          {id: root.agent_definition_id, version: root.agent_definition_version}.freeze
        end
      end

      def knowledge_snapshot(agent_id:, scope: nil)
        with_scope(scope) do |records|
          root = records.agents.load(agent_id)
          journal = records.journals.read(agent_id, limit: root.journal_position)
          JournalProjection.new(agent_root: root, records: journal).context_records.filter_map do |record|
            next unless record.kind == :knowledge
            KnowledgeItem.new(content: records.contents.fetch_text(record.content_ref), metadata: record.metadata)
          end.freeze
        end
      end

      # Participant SPI: opaque extension state, never an AgentExecution getter.
      def execution_extension(agent_id:, execution_id:, binding_key:, scope: nil)
        with_scope(scope) do |records|
          execution = records.executions.load(execution_id)
          assert_execution_owner!(execution, agent_id)
          raw = execution.metadata["execution_extension"]
          next nil unless raw
          extension = ExecutionExtensionState.from_h(raw)
          unless extension.binding_key == binding_key
            raise Phronomy::ConfigurationError, "Execution participant binding mismatch"
          end
          extension
        end
      end

      # Coordination guards are acquired first by the participant. All Agent
      # roots then use the same lexical order, including admission and purge.
      def guard_agents(scope, agent_ids:)
        participate(scope) { |records| agent_ids.map(&:to_s).uniq.sort.each { |id| records.guard_agent!(id) } }
        nil
      end

      # History release is terminal-only and preserves execution/result identity.
      def remove_execution_extension(agent_id:, execution_id:, binding_key:, scope:)
        participate(scope) do |records|
          records.guard_agent!(agent_id)
          execution = records.executions.load(execution_id)
          assert_execution_owner!(execution, agent_id)
          raise Phronomy::AgentBusyError, "Active execution history cannot be released" unless execution.terminal?
          extension = execution.metadata["execution_extension"]
          unless extension && extension.fetch("binding_key") == binding_key
            raise Phronomy::Persistence::StateConflictError, "Extension history identity mismatch"
          end
          updated = execution.with(metadata: execution.metadata.except("execution_extension"))
          records.executions.save(execution_id, expected_revision: execution.execution_revision, execution: updated)
        end
        nil
      end

      def execution_identity(execution_id, scope: nil)
        with_scope(scope) do |records|
          execution = records.executions.load(execution_id)
          ReservedExecution.new(agent_id: execution.agent_id, execution_id: execution.execution_id,
            correlation: execution.metadata["reservation"])
        end
      end

      def retained_references(agent_id:, scope: nil)
        with_scope(scope) { |records| records.retentions.list(agent_id) }
      end

      def retain(retention, scope: nil)
        with_scope(scope) do |records|
          records.guard_agent!(retention.agent_id)
          records.agents.load(retention.agent_id)
          records.retentions.retain(retention)
        end
      end

      def release_retention(agent_id:, owner_key:, scope:)
        participate(scope) { |records| records.retentions.release(agent_id: agent_id, owner_key: owner_key) }
      end

      def cancellation_requested?(agent_id:, execution_id:, scope: nil)
        with_scope(scope) { |records| records.cancellations.requested?(agent_id, execution_id) }
      end

      def request_cancellation(agent_id:, execution_id:, scope: nil)
        with_scope(scope) do |records|
          records.guard_agent!(agent_id)
          begin
            current = records.executions.load(execution_id)
          rescue Phronomy::Persistence::NotFoundError
            next false
          end
          assert_execution_owner!(current, agent_id)
          next false if current.terminal?
          records.cancellations.request(agent_id, execution_id)
          true
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

      def authorized_argument_values(entry)
        # Unit 6 persists the exact validated snapshot. Older records encoded
        # legacy raw params, whose explicit optional nil meant omission.
        entry.key?("validated_arguments") ? entry.fetch("validated_arguments") : entry.fetch("arguments").compact
      end

      def with_scope(scope, &block)
        assert_observation_thread!
        scope ? participate(scope, &block) : transaction(&block)
      end

      def assert_execution_owner!(execution, agent_id)
        unless execution.agent_id == agent_id.to_s
          raise Phronomy::Persistence::StateConflictError, "Execution owner mismatch"
        end
      end

      def assert_observation_thread!
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError, "Durable observation cannot block EventLoop"
        end
      end
    end
  end
end
