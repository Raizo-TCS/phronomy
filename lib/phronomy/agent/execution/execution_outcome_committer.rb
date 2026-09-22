# frozen_string_literal: true

require_relative "../../engine/concurrency/worker_input_restricted"

module Phronomy
  module Agent
    # Persists a completed, failed or waiting execution from captured facts.
    # Live state, admission and result delivery stay with ExecutionCoordinator.
    # @api private
    class ExecutionOutcomeCommitter
      include Phronomy::Concurrency::WorkerInputRestricted

      HandoffTerminalView = Data.define(
        :target_agent_id, :responsibility, :selection_intent,
        :llm_call_id, :tool_call_id, :policy
      )
      TerminalView = Data.define(
        :phase, :output, :usage, :approval_request, :rejected,
        :input_blocked, :output_blocked, :block_error,
        :invocation_error, :handoff, :callback_failure, :source_error, :cancel_requested
      )
      Command = Data.define(
        :execution_id, :fsm_session_id, :expected_execution_revision,
        :root, :journal_records, :execution, :runtime_snapshot,
        :terminal_view, :state_required
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
      def commit_outcome(operation)
        view = operation.terminal_view
        error = view.callback_failure&.to_stream_callback_error || view.source_error ||
          view.block_error || view.invocation_error
        if operation.execution.metadata["multi_agent_coordination_ref"] &&
            (error.is_a?(Phronomy::ExecutionRehydrationRequiredError) || view.cancel_requested)
          waiting = commit_coordination_wait(operation, error)
          return waiting if waiting
        end
        raise error if error.is_a?(Phronomy::ExecutionRehydrationRequiredError)
        return commit_failed_outcome(operation, error) if error
        return commit_suspended(operation) if view.phase == :suspended
        commit_completed(operation)
      rescue => caught
        reconcile_terminal_error(operation, caught)
      end

      private

      # Reuse the Agent barrier to retain unfinished owned children. This is an
      # active AgentExecution snapshot, not a second scheduler or terminal state.
      def commit_coordination_wait(operation, error)
        current = operation.execution
        waiting = nil
        @persistence.transaction do |tx|
          refreshed = @agent.__prepare_coordination_record(current, tx: tx)
          snapshot = tx.contents.fetch_json(refreshed.metadata.fetch("multi_agent_coordination_ref"))
          unresolved = snapshot.fetch("children").any? do |child|
            !%w[completed failed cancelled rejected blocked handed_off].include?(child.fetch("state")) &&
              !(operation.terminal_view.cancel_requested && child.fetch("state") == "reserved")
          end
          next unless unresolved
          waiting = current.with(metadata: refreshed.metadata.merge(
            "coordination_cancel_requested" => operation.terminal_view.cancel_requested || current.metadata["coordination_cancel_requested"] == true
          ))
          tx.executions.save(current.execution_id, expected_revision: current.execution_revision, execution: waiting)
        end
        return unless waiting
        coordination_wait_outcome(operation, waiting, error)
      rescue => failure
        confirmed = @persistence.executions.load(current.execution_id)
        raise failure unless waiting && confirmed.to_h == waiting.to_h
        coordination_wait_outcome(operation, confirmed, error)
      end

      def coordination_wait_outcome(operation, execution, error)
        Outcome.new(type: :coordination_wait, execution: execution, root: operation.root,
          appended_records: [].freeze, result: nil,
          error: error.is_a?(Phronomy::ExecutionRehydrationRequiredError) ? error :
            Phronomy::ExecutionRehydrationRequiredError.new("Execution #{execution.execution_id} retains unfinished children for cancellation/recovery"),
          approval_request: nil)
      end

      # F1: terminal atomicity alone does not establish commit outcome certainty.
      # Reuse an exact committed outcome; an absent/active/read-failed result is
      # never permission to write a second terminal transition.
      def reconcile_terminal_error(operation, error)
        confirmed = @persistence.executions.load(operation.execution_id)
        raise error unless confirmed.terminal? &&
          confirmed.agent_id == @agent.agent_id &&
          confirmed.execution_revision == operation.expected_execution_revision + 1
        root = @persistence.agents.load(@agent.agent_id)
        records = @persistence.journals.read(@agent.agent_id,
          after: operation.root.journal_position, limit: root.journal_position - operation.root.journal_position)
        result = @persistence.execution_result(confirmed.execution_id)
        failure = result[:error] && RecoverySupport.error_from_failure(result[:error])
        type = if failure
          :failed
        else
          ((confirmed.status == :handed_off) ? :handed_off : :completed)
        end
        Outcome.new(type: type, execution: confirmed, root: root,
          appended_records: records.freeze,
          result: failure ? nil : result_base(confirmed, root).merge(output: result[:result]).freeze,
          error: failure, approval_request: nil)
      end

      def commit_suspended(operation)
        suspended = next_root = nil
        @persistence.transaction do |tx|
          suspended = encode_suspension(tx, operation)
          save_execution(tx, operation.execution, suspended)
          next_root = save_suspended_root(tx, operation.root)
        end
        request = operation.terminal_view.approval_request
        Outcome.new(type: :suspended, execution: suspended, root: next_root,
          appended_records: [].freeze,
          result: result_base(suspended, next_root).merge(suspended: true, approval_request: request).freeze,
          error: nil, approval_request: request)
      end

      def commit_completed(operation)
        completed = next_root = appended = messages = nil
        @persistence.transaction do |tx|
          records, completed = encode_completion(tx, operation)
          appended = append_journal(tx, operation.root, records)
          completed = save_coordinated_execution(tx, operation.execution, completed)
          next_root = save_terminal_root(tx, operation.root, appended)

          # Materialization stays inside the transaction. A failure rolls back
          # the terminal transition instead of writing again from a stale base.
          messages = transcript_messages(next_root,
            operation.journal_records + Array(appended), persistence: tx)
        end
        completed_outcome(operation.terminal_view, completed, next_root, appended, messages)
      end

      def commit_failed_outcome(operation, error)
        translated_error = @agent.send(:_translated_error, error)
        failed = next_root = appended = nil
        @persistence.transaction do |tx|
          records, failed = encode_failure(tx, operation, translated_error)
          appended = append_journal(tx, operation.root, records)
          failed = save_coordinated_execution(tx, operation.execution, failed)
          next_root = save_terminal_root(tx, operation.root, appended)
        end
        Outcome.new(type: :failed, execution: failed, root: next_root,
          appended_records: Array(appended).freeze,
          result: nil, error: translated_error, approval_request: nil)
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
        output_ref = tx.contents.put_text(view.output.to_s)
        records = current.working_records + encoded_records + completion_records(operation, output_ref)
        completed = current.with(
          status: view.rejected ? :rejected : :completed,
          phase: :completed,
          working_records: [],
          llm_calls: current.llm_calls + call_records,
          approval_request: nil,
          result_ref: output_ref,
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
        error_ref = tx.contents.put_json("class" => error.class.name, "message" => error.message)
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

      def save_coordinated_execution(tx, current, updated)
        coordinated = @agent.__prepare_coordination_record(updated, tx: tx)
        synchronize_handoff_target(tx, coordinated)
        save_execution(tx, current, coordinated)
        coordinated
      end

      def synchronize_handoff_target(tx, execution)
        coordination = execution.metadata["coordination"]
        return unless coordination && coordination["kind"] == "handoff"
        routing = tx.handoff_states.load(coordination.fetch("main_agent_id"))
        return unless routing && routing.pending_target_execution_id == execution.execution_id && routing.phase != "stable"
        unless routing.active_agent_id == execution.agent_id
          raise Phronomy::Storage::ConflictError, "Handoff Target owner mismatch"
        end
        tx.handoff_states.save(routing.main_agent_id, expected_revision: routing.handoff_revision,
          state: routing.with(phase: "stable"))
      end

      def save_execution(tx, current, updated)
        tx.executions.save(current.execution_id,
          expected_revision: current.execution_revision, execution: updated)
      end

      def save_suspended_root(tx, root)
        updated = root.with(agent_revision: root.agent_revision + 1, lifecycle_status: :suspended)
        tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: updated)
        updated
      end

      def save_terminal_root(tx, root, appended)
        updated = root.with(
          agent_revision: root.agent_revision + 1,
          context_revision: root.context_revision + (appended.any?(&:context_candidate) ? 1 : 0),
          journal_position: root.journal_position + appended.length,
          lifecycle_status: :idle
        )
        tx.agents.save(root.agent_id, expected_revision: root.agent_revision, root: updated)
        updated
      end

      def completed_outcome(view, execution, root, appended, messages)
        result = result_base(execution, root).merge(
          output: view.output,
          rejected: view.rejected || nil,
          usage: view.usage,
          messages: messages
        ).compact
        Outcome.new(type: :completed, execution: execution, root: root,
          appended_records: Array(appended).freeze,
          result: result.freeze, error: nil, approval_request: nil)
      end

      def transcript_messages(root, journal_records, persistence: @persistence)
        materializer = RubyLLMMaterializer.new(
          agent: @agent,
          persistence: persistence
        )
        materializer.materialize_journal_records(
          JournalProjection.new(
            agent_root: root,
            records: journal_records
          ).transcript_records
        )
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
