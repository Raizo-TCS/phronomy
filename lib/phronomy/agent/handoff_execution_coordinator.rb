# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    # Handoff-aware specialization of the normal Agent execution coordinator.
    # It changes only the durable terminal semantics of an invocation that
    # produced a typed HandoffRequest. EventLoop ownership/apply remains entirely
    # in Agent::ExecutionCoordinator.
    class HandoffExecutionCoordinator < Phronomy::Agent::ExecutionCoordinator
      private

      def compute_terminal(operation)
        view = operation.terminal_view
        if view.callback_failure
          return commit_failed_outcome(
            operation,
            view.callback_failure.to_stream_callback_error
          )
        end
        error = view.source_error || view.block_error || view.invocation_error
        raise error if error.is_a?(Phronomy::ExecutionRehydrationRequiredError)
        return commit_failed_outcome(operation, error) if error
        return commit_suspended(operation) if view.phase == :suspended

        raise view.block_error if view.input_blocked || view.output_blocked
        raise view.invocation_error if view.invocation_error

        return commit_handed_off(operation) if view.handoff

        commit_completed(operation)
      rescue => caught
        reconcile_terminal_error(operation, caught)
      end

      def commit_handed_off(operation)
        current = operation.execution
        root = operation.root
        runtime_snapshot = operation.runtime_snapshot
        request = operation.terminal_view.handoff
        handed_off = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          coordination = current.metadata.fetch("coordination")
          main_id = coordination.fetch("main_agent_id")
          routing = tx.handoff_states.load(main_id)
          unless routing && routing.active_agent_id == @agent.agent_id && routing.handoff_revision == coordination.fetch("handoff_revision")
            raise Phronomy::Persistence::ConflictError, "Handoff routing changed before Source transfer"
          end
          if Array(routing.metadata["cancelled_execution_ids"]).include?(current.execution_id)
            raise Phronomy::CancellationError, "Handoff Source turn was cancelled"
          end
          manifest = RecoverySupport.manifest_from_ref(@agent, current.metadata.fetch("manifest_ref"))
          context = HandoffProjection.new.build_terminal(view: request, manifest: manifest,
            persistence: tx, source_agent_id: @agent.agent_id)
          context_ref = tx.contents.put_json(context.to_h)
          target_id = "handoff-target-#{Digest::SHA256.hexdigest([current.execution_id, request.target_agent_id].join("\0"))}"
          target_root = tx.agents.load(request.target_agent_id)
          target_definition = {"id" => target_root.agent_definition_id, "version" => target_root.agent_definition_version}
          transfer = routing.with(active_agent_id: request.target_agent_id,
            active_handoff_context_ref: context_ref, phase: "target_pending",
            pending_source_execution_id: current.execution_id, pending_target_execution_id: target_id,
            metadata: routing.metadata.merge("target_definition" => target_definition))
          tx.handoff_states.save(main_id, expected_revision: routing.handoff_revision, state: transfer)
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
            terminal_reason: "handed_off",
            metadata: current.metadata.merge("handoff_target_agent_id" => request.target_agent_id,
              "handoff_target_execution_id" => target_id, "handoff_context_ref" => context_ref)
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
