# frozen_string_literal: true

require_relative "../../execution/concurrency/worker_input_restricted"

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

      # Captures one participant-free decision without interpreting an ambiguous
      # response. The execution owner retains the proof and decides when to read.
      # @api private
      def commit_retained(operation, on_evidence: nil, on_outcome: nil, parent_evidence: nil)
        request = validated_approval_request(operation)
        validate_retained_operation!(operation)
        parent_evidence&.validate_target!(persistence: @persistence, operation: operation)
        evidence = nil
        result = persist_retained_decision(operation, request, parent_evidence: parent_evidence) { |captured| evidence = captured }
      rescue => original_error
        begin
          publish_retained_evidence(evidence, on_evidence, on_outcome)
        rescue
          # A collector cannot replace the original persistence failure.
          nil
        end
        raise original_error
      else
        publish_retained_evidence(evidence, on_evidence, on_outcome)
        result
      end

      private

      def validate_retained_operation!(operation)
        execution = operation.execution
        unless operation.root.agent_id == @agent_id && execution.agent_id == @agent_id &&
            operation.execution_id == execution.execution_id &&
            operation.expected_execution_revision == execution.execution_revision &&
            execution.status == :suspended && !operation.approval_request_id.empty? &&
            [true, false].include?(operation.approved)
          raise ArgumentError, "Retained approval does not match its suspended execution"
        end
        if execution.metadata["execution_extension"] ||
            execution.metadata["cancellation_requested"]
          raise ArgumentError, "Retained approval requires an uncancelled participant-free execution"
        end
      end

      def persist_retained_decision(operation, request, parent_evidence:)
        bytes = Phronomy::CanonicalJSON.dump(
          "approval_request_id" => operation.approval_request_id,
          "approved" => operation.approved
        ).b.freeze
        result = scope = nil
        @persistence.transaction do |records, current_scope|
          scope = current_scope
          ApprovalPersistenceEvidence.require_outer_scope!(scope)
          @persistence.guard_agents(scope, agent_ids: parent_evidence ? parent_evidence.agent_ids : [@agent_id])
          parent_evidence&.assert_current!(persistence: @persistence, scope: scope)
          before = ApprovalPersistenceEvidence.read(persistence: @persistence,
            agent_id: @agent_id, execution_id: operation.execution_id,
            journal_position: operation.root.journal_position, scope: scope, parent_evidence: parent_evidence)
          validate_retained_before!(operation, before)
          parent_evidence&.assert_child_before!(before)
          decision_ref = records.contents.put(bytes,
            canonicalization_version: Phronomy::CanonicalJSON::VERSION)
          decision = approval_decision(operation.execution, operation.root, decision_ref)
          execution = stage_recovery_snapshot(operation)
          updated = resumed_execution(execution, request, operation.approved, decision)
          root = resumed_root(operation.root)
          result = Result.new(execution: updated, root: root)
          evidence = ApprovalPersistenceEvidence.capture(persistence: @persistence,
            before: before, outcome: result, decision: decision, decision_bytes: bytes, parent_evidence: parent_evidence)
          yield evidence
          records.executions.save(execution.execution_id,
            expected_revision: operation.expected_execution_revision, execution: updated)
          records.agents.save(@agent_id,
            expected_revision: operation.root.agent_revision, root: root)
          after = ApprovalPersistenceEvidence.read(persistence: @persistence,
            agent_id: @agent_id, execution_id: operation.execution_id,
            journal_position: operation.root.journal_position, scope: scope, parent_evidence: parent_evidence)
          unless after == evidence.after && records.contents.fetch(decision_ref) == bytes
            raise Phronomy::Persistence::StateConflictError, "Approval write differs from its captured proof"
          end
        end
        unless scope&.committed?
          raise Phronomy::Persistence::TransactionError, "Approval decision has not committed its outer scope"
        end
        result
      end

      def validate_retained_before!(operation, before)
        snapshot = before.fetch(:agent)
        # Cancellation can win while this decision is already queued. Preserve
        # its captured bit in both proofs; the owner must honor it on either path.
        unless snapshot.fetch(0) == operation.root.to_h && snapshot.fetch(1) == operation.execution.to_h &&
            before.fetch(:journal_head) == operation.root.journal_position && snapshot.fetch(2).empty?
          raise Phronomy::Persistence::StateConflictError, "Suspended approval changed before its decision"
        end
      end

      def publish_retained_evidence(evidence, collector, outcome_collector)
        return unless evidence
        outcome_collector&.call(evidence.outcome)
        collector&.call(evidence)
      end

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
        approval_decision(execution, root, decision_ref)
      end

      def approval_decision(execution, root, decision_ref)
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
        updated = resumed_execution(current, request, approved, decision)
        tx.executions.save(
          current.execution_id,
          expected_revision: current.execution_revision,
          execution: updated
        )
        updated
      end

      def save_resumed_root(tx, current)
        updated = resumed_root(current)
        tx.agents.save(
          current.agent_id,
          expected_revision: current.agent_revision,
          root: updated
        )
        updated
      end

      def resumed_execution(current, request, approved, decision)
        current.with(status: :active, phase: :resuming,
          working_records: current.working_records + [decision],
          approval_request: request.merge("approved" => approved))
      end

      def resumed_root(current)
        current.with(agent_revision: current.agent_revision + 1, lifecycle_status: :active)
      end
    end
  end
end
