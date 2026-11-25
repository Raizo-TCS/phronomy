# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable authority for one hosted child decision. The coordinating domain
    # validates its relation once under both Agent guards; later workers compare
    # the complete captured parent footprint without rerunning participant code.
    # @api private
    class ApprovalParentEvidence
      attr_reader :parent_agent_id, :parent_execution_id, :parent_revision,
        :child_agent_id, :wait, :snapshot, :child_snapshot

      def self.capture(persistence:, parent_agent_id:, parent_execution_id:,
        parent_revision:, child_agent_id:)
        proof = scope = nil
        persistence.coordinator.atomic do |current_scope|
          scope = current_scope
          ApprovalPersistenceEvidence.require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: [parent_agent_id, child_agent_id])
          wait = yield
          unless wait.is_a?(ApprovalWait)
            raise Phronomy::AgentBusyError, "No matching hosted child approval authority"
          end
          parent_root, parent_execution, child_root, child_execution = persistence.participate(scope) do |records|
            [records.agents.load(parent_agent_id), records.executions.load(parent_execution_id),
              records.agents.load(child_agent_id), records.executions.load(wait.execution_id)]
          end
          unless parent_execution.agent_id == parent_agent_id && parent_execution.execution_revision == parent_revision &&
              parent_execution.status == :active && child_execution.agent_id == child_agent_id &&
              child_execution.execution_revision == wait.execution_revision && child_execution.status == :suspended &&
              child_execution.approval_request&.fetch("id", nil) == wait.approval_request_id
            raise Phronomy::Persistence::StateConflictError, "Hosted approval authority changed during capture"
          end
          snapshot = read_snapshot(persistence: persistence, agent_id: parent_agent_id,
            execution_id: parent_execution_id, journal_position: parent_root.journal_position, scope: scope)
          child_snapshot = read_snapshot(persistence: persistence, agent_id: child_agent_id,
            execution_id: wait.execution_id, journal_position: child_root.journal_position, scope: scope)
          if snapshot.fetch(:agent).fetch(4) || parent_execution.metadata["cancellation_requested"] ||
              child_snapshot.fetch(:agent).fetch(4) || child_execution.metadata["cancellation_requested"]
            raise Phronomy::AgentBusyError, "Hosted parent or child approval authority is cancelled"
          end
          proof = new(persistence_identity: persistence.execution_evidence_identity,
            parent_agent_id: parent_agent_id, parent_execution_id: parent_execution_id,
            parent_revision: parent_revision, child_agent_id: child_agent_id,
            wait: wait, snapshot: snapshot, child_snapshot: child_snapshot, journal_position: parent_root.journal_position)
        end
        unless scope&.committed?
          raise Phronomy::Persistence::TransactionError, "Hosted approval authority has no committed observation"
        end
        proof
      end

      def self.read_snapshot(persistence:, agent_id:, execution_id:, journal_position:, scope:)
        snapshot = ExecutionChange.read_agent_evidence(store: persistence,
          agent_id: agent_id, execution_id: execution_id, journal_position: journal_position, scope: scope)
        persistence.participate(scope) do |records|
          Phronomy::Values::Immutable.copy(agent: snapshot,
            journal_head: records.journals.head(agent_id), retentions: records.retentions.list(agent_id))
        end
      end

      def initialize(persistence_identity:, parent_agent_id:, parent_execution_id:,
        parent_revision:, child_agent_id:, wait:, snapshot:, child_snapshot:, journal_position:)
        @persistence_identity = persistence_identity
        @parent_agent_id = parent_agent_id.to_s.dup.freeze
        @parent_execution_id = parent_execution_id.to_s.dup.freeze
        @parent_revision = parent_revision
        @child_agent_id = child_agent_id.to_s.dup.freeze
        @wait = ApprovalWait.new(execution_id: wait.execution_id.to_s.dup.freeze,
          approval_request_id: wait.approval_request_id.to_s.dup.freeze, execution_revision: wait.execution_revision)
        @snapshot = Phronomy::Values::Immutable.copy(snapshot)
        @child_snapshot = Phronomy::Values::Immutable.copy(child_snapshot)
        @journal_position = journal_position
        freeze
      end
      private_class_method :new

      def agent_ids = [parent_agent_id, child_agent_id].freeze

      def validate_target!(persistence:, operation:)
        validate_store!(persistence)
        unless operation.execution.agent_id == child_agent_id && operation.execution_id == wait.execution_id &&
            operation.expected_execution_revision == wait.execution_revision &&
            operation.approval_request_id == wait.approval_request_id
          raise Phronomy::Persistence::StateConflictError, "Hosted approval proof belongs to another child wait"
        end
      end

      def read(persistence:, scope:)
        validate_store!(persistence)
        self.class.read_snapshot(persistence: persistence, agent_id: parent_agent_id,
          execution_id: parent_execution_id, journal_position: @journal_position, scope: scope)
      end

      def assert_child_before!(before)
        unless before.except(:parent) == child_snapshot
          raise Phronomy::Persistence::StateConflictError, "Hosted child approval authority changed"
        end
      end

      def assert_current!(persistence:, scope:)
        unless read(persistence: persistence, scope: scope) == snapshot
          raise Phronomy::Persistence::StateConflictError, "Hosted parent approval authority changed"
        end
      end

      private

      def validate_store!(persistence)
        unless persistence.execution_evidence_identity.equal?(@persistence_identity)
          raise Phronomy::Persistence::StateConflictError, "Hosted approval proof belongs to another Store"
        end
      end
    end
  end
end
