# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    # Adds atomic Source transfer while sharing ordinary result persistence.
    # Outcome selection deliberately retains Handoff-specific precedence.
    # @api private
    class HandoffOutcomeCommitter < ExecutionOutcomeCommitter
      # @api private
      def commit_outcome(operation)
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

      private

      def commit_handed_off(operation)
        handed_off = next_root = appended = nil
        @persistence.transaction do |tx|
          routing = validated_source_routing(tx, operation.execution)
          context_ref = persist_handoff_context(tx, operation)
          target_id = transfer_routing(tx, operation, routing, context_ref)
          records, handed_off = encode_handoff(tx, operation, target_id, context_ref)
          appended = append_journal(tx, operation.root, records)
          save_execution(tx, operation.execution, handed_off)
          next_root = save_terminal_root(tx, operation.root, appended)
        end
        Outcome.new(type: :handed_off, execution: handed_off, root: next_root,
          appended_records: Array(appended).freeze,
          result: result_base(handed_off, next_root).freeze,
          error: nil, approval_request: nil)
      end

      def validated_source_routing(tx, current)
        coordination = current.metadata.fetch("coordination")
        routing = tx.handoff_states.load(coordination.fetch("main_agent_id"))
        unless routing && routing.active_agent_id == @agent.agent_id && routing.handoff_revision == coordination.fetch("handoff_revision")
          raise Phronomy::Storage::ConflictError, "Handoff routing changed before Source transfer"
        end
        if Array(routing.metadata["cancelled_execution_ids"]).include?(current.execution_id)
          raise Phronomy::CancellationError, "Handoff Source turn was cancelled"
        end
        routing
      end

      def persist_handoff_context(tx, operation)
        manifest = SavedContextReader.manifest_from_ref(@agent, operation.execution.metadata.fetch("manifest_ref"))
        context = HandoffProjection.new.build_terminal(view: operation.terminal_view.handoff,
          manifest: manifest, persistence: tx, source_agent_id: @agent.agent_id)
        tx.contents.put_json(context.to_h)
      end

      def transfer_routing(tx, operation, routing, context_ref)
        request = operation.terminal_view.handoff
        target_id = "handoff-target-#{Digest::SHA256.hexdigest([operation.execution.execution_id, request.target_agent_id].join("\0"))}"
        target_root = tx.agents.load(request.target_agent_id)
        target_definition = {"id" => target_root.agent_definition_id, "version" => target_root.agent_definition_version}
        transfer = routing.with(active_agent_id: request.target_agent_id,
          active_handoff_context_ref: context_ref, phase: "target_pending",
          pending_source_execution_id: operation.execution.execution_id, pending_target_execution_id: target_id,
          metadata: routing.metadata.merge("target_definition" => target_definition))
        tx.handoff_states.save(routing.main_agent_id, expected_revision: routing.handoff_revision, state: transfer)
        target_id
      end

      def encode_handoff(tx, operation, target_id, context_ref)
        current = operation.execution
        request = operation.terminal_view.handoff
        encoded_records, call_records = encode_runtime_records(tx, operation, context_candidate: false)
        audit_record = encode_handoff_audit(tx, operation)
        records = current.working_records + encoded_records + [audit_record]
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
        [records, handed_off]
      end

      def encode_handoff_audit(tx, operation)
        request = operation.terminal_view.handoff
        audit_ref = tx.contents.put_json(
          "target_agent_id" => request.target_agent_id,
          "responsibility" => request.responsibility,
          "selection_intent" => request.selection_intent.to_h do |category, included|
            [category.to_s, included]
          end
        )
        JournalRecord.new(
          agent_id: @agent.agent_id,
          execution_id: operation.execution.execution_id,
          llm_call_id: request.llm_call_id,
          kind: :execution_handed_off,
          channel: :audit,
          content_ref: audit_ref,
          context_generation: operation.root.transcript_generation,
          context_candidate: false,
          metadata: {
            "target_agent_id" => request.target_agent_id,
            "handoff_tool_call_id" => request.tool_call_id
          }.compact
        )
      end
    end
  end
end
