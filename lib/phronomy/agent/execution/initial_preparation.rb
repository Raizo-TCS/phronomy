# frozen_string_literal: true

require_relative "../../engine/concurrency/worker_input_restricted"

require "securerandom"
require "time"

module Phronomy
  module Agent
    # Admits and prepares an execution, or replays its saved preparation inputs.
    # Runtime admission, live-state application and result delivery stay with
    # the execution owner. Per-operation state is kept in local variables.
    # @api private
    class InitialPreparation
      include Phronomy::Concurrency::WorkerInputRestricted

      Command = Data.define(
        :root, :journal_records, :input, :config, :preparation_replayable
      )
      RecoveryCommand = Data.define(:execution, :root, :journal_records)
      Result = Data.define(
        :execution, :root, :runtime_projection, :filtered_input,
        :config, :appended_records, :error, :admission_outcome
      )

      # @api private
      def initialize(agent:, persistence:)
        @agent = agent
        @persistence = persistence
      end

      # @api private
      def prepare(operation)
        begin
          raw_message = @agent.send(:extract_message, operation.input)
        rescue => error
          return unadmitted_result(operation, error, :not_established)
        end

        begin
          execution, active_root = admit_execution(
            raw_message,
            root: operation.root,
            mode: (operation.config[:phronomy_recovery_mode] || :invoke).to_sym,
            config: operation.config,
            preparation_replayable: operation.preparation_replayable
          )
        rescue Phronomy::AgentBusyError => error
          # A durable nonterminal execution keeps Runtime admission fail-closed
          # until recovery can establish its lineage, including after F4 loss.
          return unadmitted_result(operation, error, :recovery_required)
        rescue Phronomy::Storage::ConflictError,
          Phronomy::Storage::NotFoundError,
          Phronomy::Storage::SerializationError,
          ArgumentError,
          Phronomy::ConfigurationError => error
          return unadmitted_result(operation, error, :not_established)
        rescue => error
          return unadmitted_result(operation, error, :outcome_unknown)
        end

        prepare_admitted(
          input: operation.input,
          config: operation.config,
          execution: execution,
          active_root: active_root,
          journal_records: operation.journal_records
        )
      end

      # @api private
      def recover(operation)
        execution = operation.execution
        unless execution.metadata["preparation_replayable"] == true
          raise Phronomy::ExecutionRehydrationRequiredError,
            "execution #{execution.execution_id} has no replay-safe initial preparation contract"
        end

        input = @persistence.contents.fetch_text(execution.metadata.fetch("current_input_ref"))
        config = recovered_config(execution)
        prepare_admitted(
          input: input,
          config: config,
          execution: execution,
          active_root: operation.root,
          journal_records: operation.journal_records
        )
      end

      private

      def unadmitted_result(operation, error, outcome)
        Result.new(
          execution: nil,
          root: operation.root,
          runtime_projection: nil,
          filtered_input: nil,
          config: operation.config,
          appended_records: [].freeze,
          error: translated(error),
          admission_outcome: outcome
        )
      end

      def prepare_admitted(input:, config:, execution:, active_root:, journal_records:)
        current_execution = execution
        begin
          filtered_input = filter_input(input, config)
          staged = stage_filtered_input(current_execution, active_root, filtered_input)
          assembler, prepared = prepare_context(staged, active_root, filtered_input, config, journal_records)
          active_execution, manifest, manifest_ref = commit_preparation(
            staged, active_root, assembler, prepared
          )
          # Advance the failure base only after the commit response is known.
          # F1 response loss must not be reported as a confirmed terminal result.
          current_execution = active_execution
          projection = RubyLLMMaterializer.new(
            agent: @agent, persistence: @persistence
          ).materialize(manifest: manifest, manifest_ref: manifest_ref)
          Result.new(
            execution: active_execution,
            root: active_root,
            runtime_projection: projection,
            filtered_input: filtered_input,
            config: config,
            appended_records: [].freeze,
            error: nil,
            admission_outcome: :active
          )
        rescue => error
          preparation_failure_result(current_execution, active_root, config, error)
        end
      end

      def filter_input(input, config)
        @agent.send(:check_cancellation!, config, "invocation cancelled before input filtering")
        filtered = @agent.send(:run_input_filters!, input)
        @agent.send(:check_cancellation!, config, "invocation cancelled before context assembly")
        filtered
      end

      def stage_filtered_input(execution, root, filtered_input)
        message = @agent.send(:extract_message, filtered_input)
        # Content-addressed source material may precede Policy. Mutable execution
        # and Agent records are only advanced by the later commit transaction.
        filtered_ref = @persistence.contents.put_text(message)
        record = JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: execution.execution_id,
          kind: :external_message,
          channel: :external,
          role: :user,
          content_ref: filtered_ref,
          context_generation: root.transcript_generation,
          context_candidate: true,
          metadata: {"handoff_policy_category" => "current_request"}
        )
        execution.with(
          execution_revision: execution.execution_revision,
          working_records: execution.working_records + [record],
          metadata: execution.metadata.merge(
            "current_input_ref" => filtered_ref,
            "current_input_record_id" => record.record_id
          )
        )
      end

      def prepare_context(staged, root, input, config, journal_records)
        assembler = ContextAssembler.new(
          agent: @agent, persistence: @persistence, journal_records: journal_records
        )
        prepared = assembler.prepare_initial(
          input: input,
          agent_root: root,
          execution: staged,
          config: config,
          patch: @agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: config)
        )
        @agent.send(:check_cancellation!, config, "invocation cancelled after context policy")
        [assembler, prepared]
      end

      def commit_preparation(staged, root, assembler, prepared)
        active = manifest = manifest_ref = nil
        @persistence.transaction do |tx|
          assert_local_durable_base!(tx, root)
          manifest, manifest_ref = assembler.finalize(prepared, persistence: tx)
          active = execution_with_initial_manifest(staged, manifest_ref)
          tx.executions.save(
            staged.execution_id,
            expected_revision: staged.execution_revision,
            execution: active
          )
        end
        [active, manifest, manifest_ref]
      end

      def execution_with_initial_manifest(staged, manifest_ref)
        staged.with(
          status: :active,
          phase: :calling_llm,
          metadata: staged.metadata.merge(
            "base_manifest_ref" => manifest_ref,
            "manifest_ref" => manifest_ref,
            "manifest_refs" => [manifest_ref]
          )
        )
      end

      def admit_execution(raw_message, root:, mode: :invoke, config: {}, preparation_replayable: false)
        if root.lifecycle_status == :closed
          raise Phronomy::Error, "agent is closed: #{@agent.agent_id}"
        end

        execution = next_root = nil
        preparation_metadata = initial_preparation_metadata(mode.to_sym, preparation_replayable)
        @persistence.transaction do |tx|
          execution = build_admitted_execution(
            tx, raw_message, root: root, config: config,
            preparation_metadata: preparation_metadata
          )
          validate_coordination_admission!(tx, execution)
          tx.executions.create_active(execution)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :active
          )
          tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: next_root)
        end
        [execution, next_root]
      end

      def initial_preparation_metadata(mode, replayable)
        {
          "preparation_replayable" => !!replayable,
          RecoverySupport::CONTRACT_VERSION_KEY => RecoverySupport::CONTRACT_VERSION,
          RecoverySupport::INVOCATION_MODE_KEY => mode.to_s,
          RecoverySupport::PENDING_LLM_ID_KEY => SecureRandom.uuid.to_s.freeze,
          RecoverySupport::PENDING_LLM_STARTED_AT_KEY => Time.now.utc.iso8601(6).freeze
        }
      end

      def build_admitted_execution(tx, raw_message, root:, config:, preparation_metadata:)
        input_ref = tx.contents.put_text(raw_message)
        durable_context_ref = if config.key?(:durable_context)
          tx.contents.put_json(config.fetch(:durable_context))
        end
        input_record = JournalRecord.new(
          agent_id: @agent.agent_id,
          kind: :input_received,
          channel: :external,
          role: :user,
          content_ref: input_ref,
          context_generation: root.transcript_generation,
          context_candidate: false
        )
        execution = AgentExecution.start(
          agent_root: root,
          input_record: input_record,
          execution_id: config[:phronomy_reserved_execution_id] || SecureRandom.uuid,
          metadata: {
            "coordination" => config[:phronomy_coordination],
            "current_input_ref" => input_ref,
            "durable_context_ref" => durable_context_ref
          }.merge(preparation_metadata).compact
        )
        input_record = JournalRecord.from_h(input_record.to_h.merge("execution_id" => execution.execution_id))
        execution.with(execution_revision: 0, working_records: [input_record])
      end

      def validate_coordination_admission!(tx, execution)
        owner = execution.metadata["coordination"]
        return unless owner

        case owner.fetch("kind")
        when "team" then validate_team_admission!(tx, execution, owner)
        when "subagent" then validate_subagent_admission!(tx, execution, owner)
        when "handoff" then validate_handoff_admission!(tx, execution, owner)
        else
          raise Phronomy::ConfigurationError, "Unknown coordination owner kind"
        end
      end

      def validate_team_admission!(tx, execution, owner)
        team = tx.team_executions.load(owner.fetch("team_execution_id"))
        unless team.team_id == owner.fetch("team_id") && team.active? && !team.metadata["cancel_requested"]
          raise Phronomy::CancellationError, "Team run is no longer dispatchable"
        end
        slot = if owner.fetch("slot") == "coordinator"
          team.coordinator
        else
          assignment = team.assignments.find { |entry| entry.fetch("task_id") == owner.fetch("slot") }
          worker = assignment && team.workers.fetch(assignment.fetch("worker"))
          worker&.merge("execution_id" => assignment.fetch("execution_id"))
        end
        unless slot && slot.fetch("execution_id") == execution.execution_id && slot.fetch("agent_id") == execution.agent_id
          raise Phronomy::Storage::ConflictError, "Team reserved child identity mismatch"
        end
      end

      def validate_subagent_admission!(tx, execution, owner)
        parent = tx.executions.load(owner.fetch("parent_execution_id"))
        unless parent.agent_id == owner.fetch("parent_agent_id") && parent.active? && !parent.metadata["coordination_cancel_requested"]
          raise Phronomy::CancellationError, "Parent run is no longer dispatchable"
        end
        snapshot = tx.contents.fetch_json(parent.metadata.fetch("multi_agent_coordination_ref"))
        slot = snapshot.fetch("children").find { |entry| entry.fetch("slot") == owner.fetch("slot") }
        unless slot && slot.fetch("agent_id") == execution.agent_id && slot.fetch("execution_id") == execution.execution_id
          raise Phronomy::Storage::ConflictError, "Parent reserved child identity mismatch"
        end
      end

      def validate_handoff_admission!(tx, execution, owner)
        routing = tx.handoff_states.load(owner.fetch("main_agent_id"))
        unless routing && routing.active_agent_id == execution.agent_id
          raise Phronomy::Storage::ConflictError, "Handoff responsibility changed before admission"
        end
        if Array(routing.metadata["cancelled_execution_ids"]).include?(execution.execution_id)
          raise Phronomy::CancellationError, "Handoff reservation was cancelled"
        end
        if routing.phase != "stable" && routing.pending_target_execution_id != execution.execution_id
          raise Phronomy::Storage::ConflictError, "Handoff reserved Target identity mismatch"
        end
      end

      def recovered_config(execution)
        mode = (execution.metadata[RecoverySupport::INVOCATION_MODE_KEY] || "invoke").to_sym
        config = {phronomy_recovery_mode: mode}.merge(@agent.__coordination_config)
        if execution.metadata.key?("durable_context_ref")
          context = @persistence.contents.fetch_json(execution.metadata.fetch("durable_context_ref"))
          unless context.is_a?(Hash)
            raise Phronomy::ExecutionRehydrationRequiredError,
              "execution #{execution.execution_id} has a non-Hash durable_context"
          end
          Phronomy::Values::Immutable.validate_canonical_json!(context, label: "Recovered durable_context")
          config[:durable_context] = Phronomy::Values::Immutable.copy(context)
        end
        config.freeze
      end

      def preparation_failure_result(execution, root, config, error)
        failure = commit_preparation_failure(execution, root, error)
        Result.new(
          execution: failure.fetch(:execution),
          root: failure.fetch(:root),
          runtime_projection: nil,
          filtered_input: nil,
          config: config,
          appended_records: failure.fetch(:appended_records),
          error: failure.fetch(:error),
          admission_outcome: :terminal
        )
      end

      def commit_preparation_failure(execution, root, error)
        translated_error = translated(error)
        failed = next_root = appended = nil
        @persistence.transaction do |tx|
          error_ref = tx.contents.put_json(
            "class" => translated_error.class.name,
            "message" => translated_error.message
          )
          status = ExecutionFailure.status_for(translated_error)
          records = preparation_failure_records(execution, root, status, error_ref)
          appended = tx.journals.append(
            root.agent_id, expected_position: root.journal_position, records: records
          )
          failed = execution.with(
            status: status,
            phase: status,
            working_records: [],
            error_ref: error_ref,
            terminal_reason: translated_error.class.name
          )
          tx.executions.save(
            execution.execution_id, expected_revision: execution.execution_revision, execution: failed
          )
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: next_root)
        end
        {
          error: translated_error,
          execution: failed,
          root: next_root,
          appended_records: Array(appended).freeze
        }.freeze
      end

      def preparation_failure_records(execution, root, status, error_ref)
        records = execution.working_records.map do |record|
          JournalRecord.from_h(record.to_h.merge("context_candidate" => false))
        end
        records << JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: execution.execution_id,
          kind: ExecutionFailure.journal_kind_for(status),
          channel: :audit,
          content_ref: error_ref,
          context_generation: root.transcript_generation,
          context_candidate: false
        )
      end

      def assert_local_durable_base!(tx, root)
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: root.agent_revision,
          journal_position: root.journal_position
        )
      end

      def translated(error)
        @agent.send(:_translated_error, error)
      end
    end
  end
end
