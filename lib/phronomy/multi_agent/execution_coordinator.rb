# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Handoff-aware specialization of the normal Agent execution coordinator.
    # It changes only the durable terminal semantics of an invocation that
    # produced a typed HandoffRequest. EventLoop ownership/apply remains entirely
    # in Agent::ExecutionCoordinator.
    class ExecutionCoordinator < Phronomy::Agent::ExecutionCoordinator
      private

      def compute_terminal(operation)
        view = operation.terminal_view
        if view.callback_failure
          return commit_failed_outcome(
            operation,
            view.callback_failure.to_stream_callback_error
          )
        end
        return commit_failed_outcome(operation, view.source_error) if view.source_error
        return commit_suspended(operation) if view.phase == :suspended

        raise view.block_error if view.input_blocked || view.output_blocked
        raise view.invocation_error if view.invocation_error

        return commit_handed_off(operation) if view.handoff

        commit_completed(operation)
      rescue => caught
        commit_failed_outcome(operation, caught)
      end

      def commit_handed_off(operation)
        current = operation.execution
        root = operation.root
        runtime_snapshot = operation.runtime_snapshot
        request = operation.terminal_view.handoff
        handed_off = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          encoded_records, call_records = encode_runtime_records(
            current,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: false,
            agent_root: root
          )
          audit_ref = tx.contents.put_json(
            "target_agent_id" => request.target_agent_id,
            "responsibility" => request.responsibility,
            "selection_intent" => request.selection_intent.to_h do |category, included|
              [category.to_s, included]
            end
          )
          audit_record = Phronomy::Agent::JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            llm_call_id: request.llm_call_id,
            kind: :execution_handed_off,
            channel: :audit,
            content_ref: audit_ref,
            context_generation: root.transcript_generation,
            context_candidate: false,
            metadata: {
              "target_agent_id" => request.target_agent_id,
              "handoff_tool_call_id" => request.tool_call_id
            }.compact
          )

          all_records = current.working_records + encoded_records + [audit_record]
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: all_records
          )
          handed_off = current.with(
            status: :handed_off,
            phase: :handed_off,
            working_records: [],
            llm_calls: current.llm_calls + call_records,
            approval_request: nil,
            terminal_reason: "handed_off"
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: handed_off
          )
          context_changed = appended.any?(&:context_candidate)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + (context_changed ? 1 : 0),
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end

        result = result_base(handed_off, next_root)
        TerminalOutcome.new(
          type: :handed_off,
          execution: handed_off,
          root: next_root,
          appended_records: Array(appended).freeze,
          result: result.freeze,
          error: nil,
          approval_request: nil
        )
      end
    end
  end
end
