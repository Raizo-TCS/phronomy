# frozen_string_literal: true

require_relative "../../engine/concurrency/worker_input_restricted"

module Phronomy
  module Agent
    # Commits the operation-specific prerequisites for Provider/Tool dispatch.
    # The Agent supplies existing context/hook services, never live-state writes.
    # Inputs and results belong to this worker boundary; delivery stays with the
    # execution owner. No operation-local state is retained between calls.
    # @api private
    class DispatchPreparation
      include Phronomy::Concurrency::WorkerInputRestricted

      ProviderCommand = Data.define(
        :execution_id, :fsm_session_id, :expected_execution_revision,
        :root, :journal_records, :execution, :base_manifest,
        :invocation_config, :runtime_snapshot, :streaming,
        :pending_llm_call_id, :pending_llm_started_at
      )
      ToolCommand = Data.define(
        :execution_id, :fsm_session_id, :expected_execution_revision,
        :root, :execution, :runtime_snapshot, :tool_batch_snapshot
      )
      ProviderReconciliationCommand = Data.define(
        :operation, :intended_result, :original_error
      )
      ToolReconciliationCommand = Data.define(
        :operation, :intended_result, :original_error
      )
      ProviderResult = Data.define(:execution, :runtime_projection, :error)
      ToolResult = Data.define(:execution)
      ProviderReconciliationResult = Data.define(:disposition, :preparation_result)
      ToolReconciliationResult = Data.define(:disposition, :preparation_result)

      # A failed response does not prove that the execution save rolled back.
      # @api private
      class OutcomeUnknownError < Phronomy::Error
        attr_reader :original_error, :intended_result

        def initialize(original_error, intended_result)
          @original_error = original_error
          @intended_result = intended_result
          super(
            "durable dispatch preparation outcome is uncertain: " \
              "#{original_error.class}: #{original_error.message}"
          )
          set_backtrace(original_error.backtrace)
        end
      end

      # @api private
      def initialize(agent:, persistence:)
        @agent = agent
        @persistence = persistence
      end

      # @api private
      def prepare_provider(operation)
        staged = stage_provider_call(operation)
        recorded = encode_provider_records(operation, staged)
        assembler, prepared = prepare_provider_context(operation, recorded)
        committed, manifest, manifest_ref = commit_provider_preparation(
          operation, recorded, assembler, prepared
        )
        materialize_provider_result(committed.execution, manifest, manifest_ref)
      end

      # @api private
      def prepare_tools(operation)
        intended = nil
        begin
          @persistence.transaction do |tx|
            assert_local_durable_base!(tx, operation.root)
            updated = build_tool_dispatch_execution(operation, tx)
            updated = @agent.__prepare_coordination_record(updated, tx: tx)
            tx.executions.save(
              operation.execution.execution_id,
              expected_revision: operation.execution.execution_revision,
              execution: updated
            )
            intended = ToolResult.new(execution: updated)
          end
        rescue => caught
          raise if known_durable_failure?(caught) || intended.nil?

          raise OutcomeUnknownError.new(caught, intended)
        end
        intended
      end

      # @api private
      def reconcile_provider(command)
        disposition, current = reconcile_preparation(
          command.operation, command.intended_result.execution
        )
        result = restore_provider_result(current) if disposition == :committed
        ProviderReconciliationResult.new(
          disposition: disposition, preparation_result: result
        )
      end

      # @api private
      def reconcile_tools(command)
        disposition, current = reconcile_preparation(
          command.operation, command.intended_result.execution
        )
        result = ToolResult.new(execution: current) if disposition == :committed
        ToolReconciliationResult.new(
          disposition: disposition, preparation_result: result
        )
      end

      private

      def stage_provider_call(operation)
        metadata = operation.execution.metadata.dup
        metadata.delete(ExecutionMetadata::TOOL_BATCH_METADATA_KEY)
        metadata.delete(ExecutionMetadata::RECOVERY_METADATA_KEY)
        metadata[ExecutionMetadata::PENDING_LLM_ID_KEY] = operation.pending_llm_call_id
        metadata[ExecutionMetadata::PENDING_LLM_STARTED_AT_KEY] = operation.pending_llm_started_at
        metadata[ExecutionMetadata::CONTRACT_VERSION_KEY] = ExecutionMetadata::CONTRACT_VERSION
        operation.execution.with(
          execution_revision: operation.execution.execution_revision,
          metadata: metadata
        )
      end

      def encode_provider_records(operation, staged)
        encoded_records = call_records = nil
        # Content-addressed records may be added here; Execution is not advanced.
        @persistence.transaction do |tx|
          assert_local_durable_base!(tx, operation.root)
          encoded_records, call_records = RuntimeRecordEncoder.encode(
            staged,
            agent_id: @agent.agent_id,
            tx: tx,
            snapshot: operation.runtime_snapshot,
            context_candidate: true,
            agent_root: operation.root
          )
        end
        staged.with(
          execution_revision: staged.execution_revision,
          phase: :preparing_llm_call,
          working_records: staged.working_records + encoded_records,
          llm_calls: staged.llm_calls + call_records
        )
      end

      def prepare_provider_context(operation, recorded)
        patch = @agent.send(
          :run_before_llm_input_hooks,
          call_sequence: recorded.llm_calls.length + 1,
          config: operation.invocation_config
        )
        assembler = ContextAssembler.new(
          agent: @agent,
          persistence: @persistence,
          journal_records: operation.journal_records
        )
        prepared = assembler.prepare_followup(
          base_manifest: operation.base_manifest,
          agent_root: operation.root,
          execution: recorded,
          config: operation.invocation_config,
          patch: patch
        )
        @agent.send(
          :check_cancellation!,
          operation.invocation_config,
          "invocation cancelled after context policy"
        )
        [assembler, prepared]
      end

      def commit_provider_preparation(operation, recorded, assembler, prepared)
        manifest = manifest_ref = intended = nil
        begin
          @persistence.transaction do |tx|
            assert_local_durable_base!(tx, operation.root)
            manifest, manifest_ref = assembler.finalize(prepared, persistence: tx)
            updated = execution_with_provider_manifest(recorded, manifest_ref)
            updated = @agent.__prepare_coordination_record(updated, tx: tx)
            tx.executions.save(
              operation.execution.execution_id,
              expected_revision: operation.execution.execution_revision,
              execution: updated
            )
            intended = ProviderResult.new(
              execution: updated, runtime_projection: nil, error: nil
            )
          end
        rescue => caught
          raise if known_durable_failure?(caught) || intended.nil?

          raise OutcomeUnknownError.new(caught, intended)
        end
        [intended, manifest, manifest_ref]
      end

      def execution_with_provider_manifest(recorded, manifest_ref)
        refs = Array(recorded.metadata["manifest_refs"]) + [manifest_ref]
        recorded.with(
          phase: :calling_llm,
          metadata: recorded.metadata.merge(
            "manifest_ref" => manifest_ref,
            "manifest_refs" => refs
          )
        )
      end

      def materialize_provider_result(execution, manifest, manifest_ref)
        projection = materialization_error = nil
        begin
          projection = RubyLLMMaterializer.new(
            agent: @agent, persistence: @persistence
          ).materialize(manifest: manifest, manifest_ref: manifest_ref)
        rescue => error
          materialization_error = error
        end
        ProviderResult.new(
          execution: execution, runtime_projection: projection,
          error: materialization_error
        )
      end

      def restore_provider_result(execution)
        projection = materialization_error = nil
        begin
          _manifest, projection = SavedContextReader.materialize_projection(
            @agent, execution.metadata.fetch("manifest_ref")
          )
        rescue => error
          materialization_error = error
        end
        ProviderResult.new(
          execution: execution, runtime_projection: projection,
          error: materialization_error
        )
      end

      def build_tool_dispatch_execution(operation, tx)
        encoded_records, call_records = RuntimeRecordEncoder.encode(
          operation.execution,
          agent_id: @agent.agent_id,
          tx: tx,
          snapshot: operation.runtime_snapshot,
          context_candidate: true,
          agent_root: operation.root
        )
        operation.execution.with(
          phase: :dispatching_tools,
          working_records: operation.execution.working_records + encoded_records,
          llm_calls: operation.execution.llm_calls + call_records,
          metadata: tool_dispatch_metadata(operation)
        )
      end

      def tool_dispatch_metadata(operation)
        metadata = operation.execution.metadata.dup
        metadata.delete(ExecutionMetadata::PENDING_LLM_ID_KEY)
        metadata.delete(ExecutionMetadata::PENDING_LLM_STARTED_AT_KEY)
        metadata.delete(ExecutionMetadata::RECOVERY_METADATA_KEY)
        metadata.delete("framework_calls_pending")
        metadata[ExecutionMetadata::TOOL_BATCH_METADATA_KEY] =
          Phronomy::Values::Serializable.convert(operation.tool_batch_snapshot,
            unsupported_message: "Recovery value is not canonically serializable")
        metadata[ExecutionMetadata::CONTRACT_VERSION_KEY] = ExecutionMetadata::CONTRACT_VERSION
        metadata
      end

      def reconcile_preparation(operation, intended_execution)
        current = @persistence.executions.load(operation.execution_id)
        if current.execution_revision == intended_execution.execution_revision &&
            current.to_h == intended_execution.to_h
          return [:committed, current]
        end
        if current.execution_revision == operation.execution.execution_revision &&
            current.to_h == operation.execution.to_h
          return [:not_committed, current]
        end

        [:conflict, current]
      end

      def known_durable_failure?(error)
        error.is_a?(Phronomy::Persistence::ConflictError) ||
          error.is_a?(Phronomy::Persistence::NotFoundError) ||
          error.is_a?(Phronomy::Persistence::SerializationError) ||
          error.is_a?(Phronomy::Persistence::UnsupportedBackendError) ||
          error.is_a?(ArgumentError) ||
          error.is_a?(Phronomy::ConfigurationError)
      end

      def assert_local_durable_base!(tx, root)
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: root.journal_position
        )
      end
    end
  end
end
