# frozen_string_literal: true

require_relative "../../execution/concurrency/worker_input_restricted"

module Phronomy
  module Agent
    # Persists a completed, failed or waiting execution from captured facts.
    # Live state, admission and result delivery stay with ExecutionCoordinator.
    # @api private
    class ExecutionOutcomeCommitter
      include Phronomy::Concurrency::WorkerInputRestricted

      TerminalView = Data.define(
        :phase, :output, :usage, :approval_request, :rejected,
        :input_blocked, :output_blocked, :block_error,
        :invocation_error, :handoff, :callback_failure, :source_error, :cancel_requested, :response
      ) do
        def initialize(response: nil, **values)
          super(**values, response: response)
        end
      end
      Command = Data.define(
        :execution_id, :fsm_session_id, :expected_execution_revision,
        :root, :journal_records, :execution, :runtime_snapshot,
        :terminal_view, :state_required, :wiring
      )
      Outcome = Data.define(
        :type, :execution, :root, :appended_records,
        :result, :error, :approval_request
      )

      # @api private
      def initialize(agent:, persistence:)
        @agent = agent
        @persistence = persistence
      end

      # @api private
      def commit_outcome(operation, on_evidence: nil, on_outcome: nil, on_prepared: nil, on_preparation: nil)
        view = operation.terminal_view
        error = view.callback_failure&.to_stream_callback_error || view.source_error ||
          view.block_error || view.invocation_error
        if !error && !view.rejected && !view.handoff && view.phase != :suspended
          begin
            contract = OutputContract.restore(operation.execution, @persistence.contents)
            if contract
              output = contract.validate(view.output, response: view.response, execution_id: operation.execution_id)
              view = view.with(output: output)
              operation = operation.with(terminal_view: view)
            end
          rescue => validation_error
            error = validation_error
          end
        end
        participant = operation.wiring[:phronomy_execution_participant]
        capture = on_evidence && outcome_evidence_eligible?(operation, error, participant)
        prepared = capture && participant&.respond_to?(:commit_prepared_outcome, true)
        writes = [] if capture
        change = nil
        prepare = if prepared
          ->(records, state, pending) { prepare_terminal_outcome(records, operation, state, pending, error, change.cancel_requested) }
        end
        capture_preparation = if prepared
          lambda do |values, plan|
            preparation = OutcomePreparation.new(values, plan.writes, journal_records: plan.journal_records,
              persistence: @agent.persistence, participant: participant)
            # Only the completed transcript suffix is safe to materialize again.
            # Wait diagnostics and approval conversion retain their old boundary.
            on_preparation&.call(preparation) if plan.journal_records
            preparation
          end
        end
        publish = if prepared
          lambda do |input|
            on_prepared&.call(input)
            on_outcome&.call(input.values.fetch(:result))
            evidence = input.materialize(persistence: @agent.persistence)
            on_evidence.call(evidence) if evidence
            evidence
          end
        end
        change = ExecutionChange.new(agent: @agent, current: operation.execution,
          root: operation.root, kind: :terminal, terminal: view, config: operation.wiring,
          prepare_outcome: prepare, on_preparation: capture_preparation, on_prepared: publish) do |tx, state, receipt, pending|
          if pending
            waiting = operation.execution.with(metadata: extension_metadata(operation.execution, state).merge(
              "cancellation_requested" => change.cancel_requested || operation.execution.metadata["cancellation_requested"] == true
            ))
            save_execution(tx, operation.execution, waiting)
            Outcome.new(type: :coordination_wait, execution: waiting, root: operation.root,
              appended_records: [].freeze, result: nil,
              error: error || Phronomy::ExecutionRehydrationRequiredError.new("Execution retains unfinished participant work"), approval_request: nil)
          else
            raise error if error.is_a?(Phronomy::ExecutionRehydrationRequiredError)
            records = capture ? TerminalPersistenceEvidence.recording_scope(tx, writes) : tx
            commit_terminal(records, operation, state, receipt, error)
          end
        end
        (capture && !prepared) ? perform_with_evidence(change, writes, on_evidence, on_outcome, participant) : change.perform
      end

      private

      def outcome_evidence_eligible?(operation, error, participant)
        return false unless operation.state_required && !operation.terminal_view.handoff
        if participant
          %i[active suspended].include?(operation.execution.status) && participant.respond_to?(:outcome_recovery_supported?, true) &&
            participant.send(:outcome_recovery_supported?, execution: operation.execution, persistence: @persistence)
        else
          operation.execution.status == :active && operation.terminal_view.phase != :suspended && !error.is_a?(Phronomy::ExecutionRehydrationRequiredError) &&
            !operation.execution.metadata["execution_extension"]
        end
      end

      def perform_with_evidence(change, writes, collector, outcome_collector, participant)
        result = change.perform
      rescue => original_error
        begin
          publish_evidence(change, writes, collector, outcome_collector, participant)
        rescue => capture_error
          begin
            Phronomy::RuntimeSettings.current.logger&.warn(
              "[Phronomy] Agent outcome evidence collector failed: #{capture_error.class}: #{capture_error.message}"
            )
          rescue
            nil
          end
        end
        raise original_error
      else
        # Collector failure after a successful commit propagates; the collector
        # must not interpret its own failure as proof that persistence failed.
        publish_evidence(change, writes, collector, outcome_collector, participant)
        result
      end

      def publish_evidence(change, writes, collector, outcome_collector, participant)
        values = change.captured_evidence
        outcome_collector&.call(values.fetch(:result)) if values
        evidence = TerminalPersistenceEvidence.capture(change, writes, persistence: @agent.persistence, participant: participant)
        collector.call(evidence) if evidence
      end

      def prepare_terminal_outcome(records, operation, state, pending, error, cancellation_requested)
        contents = OutcomeWritePlan::Contents.new(records.contents, write_class: TerminalPersistenceEvidence::ContentWrite)
        view = OutcomeWritePlan::ContentView.new(contents: contents)
        outcome = if pending
          waiting = operation.execution.with(metadata: extension_metadata(operation.execution, state).merge(
            "cancellation_requested" => cancellation_requested || operation.execution.metadata["cancellation_requested"] == true
          ))
          Outcome.new(type: :coordination_wait, execution: waiting, root: operation.root,
            appended_records: [].freeze, result: nil,
            error: error || Phronomy::ExecutionRehydrationRequiredError.new("Execution retains unfinished participant work"), approval_request: nil)
        else
          raise error if error.is_a?(Phronomy::ExecutionRehydrationRequiredError)
          commit_terminal(view, operation, state, nil, error, prepare: true)
        end
        journal_records = operation.journal_records + outcome.appended_records if outcome.type == :completed
        OutcomeWritePlan.new(outcome: outcome, writes: contents.writes, journal_records: journal_records)
      end

      def commit_terminal(tx, operation, state, receipt, error, prepare: false)
        view = operation.terminal_view
        if !error && view.phase == :suspended
          suspended = encode_suspension(tx, operation)
          suspended = with_extension(suspended, state)
          save_execution(tx, operation.execution, suspended) unless prepare
          root = prepare ? suspended_root(operation.root) : save_suspended_root(tx, operation.root)
          return Outcome.new(type: :suspended, execution: suspended, root: root,
            appended_records: [].freeze,
            result: result_base(suspended, root).merge(suspended: true, approval_request: view.approval_request).freeze,
            error: nil, approval_request: view.approval_request)
        end
        records, execution = if error
          encode_failure(tx, operation, error)
        elsif view.handoff
          raise Phronomy::ConfigurationError, "Control transfer needs a transaction participant" unless receipt
          encode_transfer(tx, operation, receipt)
        else
          encode_completion(tx, operation)
        end
        execution = with_extension(execution, state)
        appended = prepare ? records.each_with_index.map { |record, index| record.with_sequence(operation.root.journal_position + index + 1) } : append_journal(tx, operation.root, records)
        save_execution(tx, operation.execution, execution) unless prepare
        root = prepare ? terminal_root(operation.root, appended) : save_terminal_root(tx, operation.root, appended)
        if error
          Outcome.new(type: :failed, execution: execution, root: root, appended_records: appended.freeze,
            result: nil, error: error, approval_request: nil)
        elsif view.handoff
          Outcome.new(type: :handed_off, execution: execution, root: root, appended_records: appended.freeze,
            result: result_base(execution, root).freeze, error: nil, approval_request: nil)
        else
          messages = transcript_messages(root, operation.journal_records + appended, persistence: tx) unless prepare
          completed_outcome(view, execution, root, appended, messages)
        end
      end

      def extension_metadata(execution, state)
        execution.metadata.merge("execution_extension" => state&.to_h).compact
      end

      def with_extension(execution, state)
        execution.with(execution_revision: execution.execution_revision, metadata: extension_metadata(execution, state))
      end

      def encode_transfer(tx, operation, receipt)
        request = operation.terminal_view.handoff
        unless receipt.fetch("target_agent_id") == request.target_agent_id &&
            !receipt.fetch("target_execution_id").to_s.empty? && !receipt.fetch("context_ref").to_s.empty?
          raise Phronomy::Persistence::StateConflictError, "Control transfer receipt mismatch"
        end
        current = operation.execution
        encoded, calls = encode_runtime_records(tx, operation, context_candidate: false)
        audit_ref = tx.contents.put_json("target_agent_id" => request.target_agent_id,
          "responsibility" => request.responsibility, "selection" => request.selection.transform_keys(&:to_s))
        audit = JournalRecord.new(agent_id: @agent.agent_id, execution_id: current.execution_id,
          llm_call_id: request.llm_call_id, kind: :execution_handed_off, channel: :audit,
          content_ref: audit_ref, context_generation: operation.root.transcript_generation, context_candidate: false,
          metadata: {"target_agent_id" => request.target_agent_id, "handoff_tool_call_id" => request.tool_call_id}.compact)
        updated = current.with(status: :handed_off, phase: :handed_off, working_records: [],
          llm_calls: current.llm_calls + calls, approval_request: nil, terminal_reason: "handed_off",
          metadata: current.metadata.merge("transfer_receipt" => receipt))
        [current.working_records + encoded + [audit], updated]
      end

      def encode_suspension(tx, operation)
        current = operation.execution
        request = operation.terminal_view.approval_request
        encoded_records, call_records = encode_runtime_records(tx, operation, context_candidate: true)
        request_ref = tx.contents.put_json(RuntimeRecordEncoder.json_value(request.to_h))
        approval_record = JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: current.execution_id,
          kind: :approval_required,
          channel: :approval,
          content_ref: request_ref,
          context_generation: operation.root.transcript_generation,
          context_candidate: false
        )
        current.with(
          status: :suspended,
          phase: :approval,
          working_records: current.working_records + encoded_records + [approval_record],
          llm_calls: current.llm_calls + call_records,
          approval_request: RuntimeRecordEncoder.json_value(request.to_h)
        )
      end

      def encode_completion(tx, operation)
        current = operation.execution
        view = operation.terminal_view
        encoded_records, call_records = encode_runtime_records(tx, operation, context_candidate: true)
        structured = current.metadata.key?("output_contract") && !view.rejected
        output_ref = tx.contents.put_text(structured ? JSON.generate(view.output) : view.output.to_s)
        output_metadata = structured ? {"result_format" => "json", "raw_output_ref" => tx.contents.put_text(view.response.content)} : {}
        records = current.working_records + encoded_records + completion_records(operation, output_ref)
        completed = current.with(
          status: view.rejected ? :rejected : :completed,
          phase: :completed,
          working_records: [],
          llm_calls: current.llm_calls + call_records,
          approval_request: nil,
          result_ref: output_ref,
          metadata: current.metadata.merge(output_metadata),
          terminal_reason: view.rejected ? "rejected" : "completed"
        )
        [records, completed]
      end

      def completion_records(operation, output_ref)
        final_output = JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: operation.execution.execution_id,
          kind: :final_output,
          channel: :audit,
          role: :assistant,
          content_ref: output_ref,
          context_generation: operation.root.transcript_generation,
          context_candidate: false
        )
        completed = JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: operation.execution.execution_id,
          kind: operation.terminal_view.rejected ? :execution_rejected : :execution_completed,
          channel: :audit,
          content_ref: output_ref,
          context_generation: operation.root.transcript_generation,
          context_candidate: false
        )
        [final_output, completed]
      end

      def encode_failure(tx, operation, error)
        current = operation.execution
        encoded_records, call_records = encode_runtime_records(tx, operation, context_candidate: false)
        error_ref = tx.contents.put_json(error.is_a?(OutputError) ? error.diagnostic : Phronomy::Error.diagnostic(error))
        terminal_status = ExecutionFailure.status_for(error)
        records = failure_records(operation, encoded_records, terminal_status, error_ref)
        failed = current.with(
          status: terminal_status,
          phase: terminal_status,
          working_records: [],
          llm_calls: current.llm_calls + call_records,
          error_ref: error_ref,
          terminal_reason: error.class.name
        )
        [records, failed]
      end

      def failure_records(operation, encoded_records, status, error_ref)
        audit_records = (operation.execution.working_records + encoded_records).map do |record|
          JournalRecord.from_h(record.to_h.merge("context_candidate" => false))
        end
        audit_records << JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: operation.execution.execution_id,
          kind: ExecutionFailure.journal_kind_for(status),
          channel: :audit,
          content_ref: error_ref,
          context_generation: operation.root.transcript_generation,
          context_candidate: false
        )
      end

      def encode_runtime_records(tx, operation, context_candidate:)
        RuntimeRecordEncoder.encode(operation.execution,
          agent_id: @agent.agent_id, tx: tx, snapshot: operation.runtime_snapshot,
          context_candidate: context_candidate, agent_root: operation.root)
      end

      def append_journal(tx, root, records)
        tx.journals.append(root.agent_id,
          expected_position: root.journal_position, records: records)
      end

      def save_execution(tx, current, updated)
        tx.executions.save(current.execution_id,
          expected_revision: current.execution_revision, execution: updated)
      end

      def save_suspended_root(tx, root)
        updated = suspended_root(root)
        tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: updated)
        updated
      end

      def save_terminal_root(tx, root, appended)
        updated = terminal_root(root, appended)
        tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: updated)
        updated
      end

      def suspended_root(root)
        root.with(agent_revision: root.agent_revision + 1, lifecycle_status: :suspended)
      end

      def terminal_root(root, appended)
        root.with(
          agent_revision: root.agent_revision + 1,
          context_revision: root.context_revision + (appended.any?(&:context_candidate) ? 1 : 0),
          journal_position: root.journal_position + appended.length,
          lifecycle_status: :idle
        )
      end

      def completed_outcome(view, execution, root, appended, messages)
        result = result_base(execution, root).merge(
          output: view.output,
          raw_output: (execution.metadata["result_format"] == "json") ? view.response.content : nil,
          rejected: view.rejected || nil,
          usage: view.usage,
          messages: messages
        ).compact
        Outcome.new(type: :completed, execution: execution, root: root,
          appended_records: Array(appended).freeze,
          result: result.freeze, error: nil, approval_request: nil)
      end

      def transcript_messages(root, journal_records, persistence: @persistence)
        materializer = RuntimeInput.new(
          agent: @agent,
          persistence: persistence
        )
        materializer.materialize_transcript(root: root, records: journal_records)
      end

      def result_base(execution, root)
        {
          agent_id: root.agent_id,
          execution_id: execution.execution_id,
          agent_revision: root.agent_revision,
          context_revision: root.context_revision,
          journal_position: root.journal_position
        }
      end
    end
  end
end
