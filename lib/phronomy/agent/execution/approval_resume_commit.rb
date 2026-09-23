# frozen_string_literal: true

require_relative "../../engine/concurrency/worker_input_restricted"

module Phronomy
  module Agent
    # Persists one approval decision with its captured recovery facts.
    # Admission, live state and session resumption stay with the execution owner.
    # @api private
    class ApprovalResumeCommit
      include Phronomy::Concurrency::WorkerInputRestricted

      Command = Data.define(
        :execution_id, :expected_execution_revision,
        :root, :execution, :approval_request_id, :approved, :tool_batch_snapshot
      )
      Result = Data.define(:execution, :root)

      # @api private
      def initialize(agent_id:, persistence:)
        @agent_id = agent_id
        @persistence = persistence
      end

      # @api private
      def commit(operation)
        request = validated_approval_request(operation)
        execution = stage_recovery_snapshot(operation)
        persist_decision(execution, operation.root, request, operation.approved)
      end

      private

      def validated_approval_request(operation)
        request = operation.execution.approval_request || {}
        request_id = request["id"] || request[:id]
        unless request_id.to_s == operation.approval_request_id
          raise ArgumentError,
            "approval request does not match execution #{operation.execution.execution_id}"
        end
        request
      end

      def stage_recovery_snapshot(operation)
        return operation.execution unless operation.tool_batch_snapshot

        ExecutionMetadata.with_values(
          operation.execution,
          ExecutionMetadata::TOOL_BATCH_METADATA_KEY => operation.tool_batch_snapshot
        )
      end

      def persist_decision(execution, root, request, approved)
        updated = next_root = nil
        @persistence.transaction do |tx|
          decision = record_decision(tx, execution, root, request, approved)
          updated = save_resumed_execution(tx, execution, request, approved, decision)
          next_root = save_resumed_root(tx, root)
        end
        Result.new(execution: updated, root: next_root)
      end

      def record_decision(tx, execution, root, request, approved)
        decision_ref = tx.contents.put_json(
          "approval_request_id" => (request["id"] || request[:id]).to_s,
          "approved" => approved
        )
        JournalRecord.new(
          agent_id: @agent_id,
          execution_id: execution.execution_id,
          kind: :approval_decided,
          channel: :approval,
          content_ref: decision_ref,
          context_generation: root.transcript_generation,
          context_candidate: false
        )
      end

      def save_resumed_execution(tx, current, request, approved, decision)
        updated = current.with(
          status: :active,
          phase: :resuming,
          working_records: current.working_records + [decision],
          approval_request: request.merge("approved" => approved)
        )
        tx.executions.save(
          current.execution_id,
          expected_revision: current.execution_revision,
          execution: updated
        )
        updated
      end

      def save_resumed_root(tx, current)
        updated = current.with(
          agent_revision: current.agent_revision + 1,
          lifecycle_status: :active
        )
        tx.agents.save(
          current.agent_id,
          expected_revision: current.agent_revision,
          root: updated
        )
        updated
      end
    end
  end
end
