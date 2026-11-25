# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Process-local proof of one participant-free approval decision. It retains only
    # immutable facts and requires the original Store after the write has settled.
    # Reconciliation never resumes execution or repeats persistence writes.
    # @api private
    class ApprovalPersistenceEvidence
      Result = Data.define(:disposition, :evidence, :original_error, :read_error)

      attr_reader :before, :after, :outcome, :attempt_id, :agent_id, :execution_id,
        :approval_request_id, :approved, :decision, :decision_bytes

      def self.require_outer_scope!(scope)
        return if scope.outermost?
        raise Phronomy::Persistence::TransactionError, "Approval evidence requires its own outer transaction"
      end

      def self.read(persistence:, agent_id:, execution_id:, journal_position:, scope:, parent_evidence: nil)
        snapshot = ExecutionChange.read_agent_evidence(store: persistence,
          agent_id: agent_id, execution_id: execution_id,
          journal_position: journal_position, scope: scope)
        result = persistence.participate(scope) do |records|
          {agent: snapshot, journal_head: records.journals.head(agent_id),
           retentions: records.retentions.list(agent_id)}
        end
        result[:parent] = parent_evidence.read(persistence: persistence, scope: scope) if parent_evidence
        Phronomy::Values::Immutable.copy(result)
      end

      def self.capture(persistence:, before:, outcome:, decision:, decision_bytes:, parent_evidence: nil)
        new(persistence.execution_evidence_identity, before, outcome, decision, decision_bytes, parent_evidence)
      end

      def initialize(persistence_identity, before, outcome, decision, decision_bytes, parent_evidence)
        @persistence_identity = persistence_identity
        @parent_evidence = parent_evidence
        @before = Phronomy::Values::Immutable.copy(before)
        @outcome, @decision = outcome, decision
        @agent_id, @execution_id = outcome.execution.agent_id, outcome.execution.execution_id
        @approval_request_id = outcome.execution.approval_request.fetch("id")
        @approved = outcome.execution.approval_request.fetch("approved")
        @journal_position = before.fetch(:agent).fetch(0).fetch("journal_position")
        intended = before.fetch(:agent).dup
        intended[0], intended[1] = outcome.root.to_h, outcome.execution.to_h
        @after = Phronomy::Values::Immutable.copy(before.merge(agent: intended))
        @decision_bytes = decision_bytes.b.dup.freeze
        @attempt_id = SecureRandom.uuid.freeze
        freeze
      end
      private_class_method :new

      def reconcile(persistence:, original_error: nil)
        unless persistence.execution_evidence_identity.equal?(@persistence_identity)
          raise Phronomy::Persistence::StateConflictError, "Approval evidence belongs to another Store"
        end
        disposition = persistence.coordinator.atomic do |scope|
          self.class.require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: @parent_evidence ? @parent_evidence.agent_ids : [agent_id])
          snapshot = self.class.read(persistence: persistence,
            agent_id: agent_id, execution_id: execution_id,
            journal_position: @journal_position, scope: scope, parent_evidence: @parent_evidence)
          classification = Phronomy::Persistence::SaveOutcome.compare(before: before, after: after) { snapshot }
          if classification.disposition == :committed
            persistence.participate(scope) do |records|
              unless records.contents.fetch(decision.content_ref) == decision_bytes
                raise Phronomy::ContentStore::IntegrityError, "Approval decision differs from its captured bytes"
              end
            end
          end
          classification.disposition
        end
        result(disposition, original_error: original_error)
      rescue => error
        result(:unknown, original_error: original_error, read_error: error)
      end

      private

      def result(disposition, original_error:, read_error: nil)
        Result.new(disposition: disposition, evidence: self,
          original_error: original_error, read_error: read_error)
      end
    end
  end
end
