# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Detached proof of one standalone pre-dispatch execution change. The proof
    # does not authorize external dispatch or retain live Agent/participant state.
    # Only the original Store may compare or repeat the captured execution save,
    # after the prior backend attempt has settled and authoritative reads apply.
    # @api private
    class DispatchPersistenceEvidence
      Result = Data.define(:disposition, :evidence, :original_error, :read_error)

      attr_reader :before, :after, :execution, :kind, :manifest, :manifest_ref,
        :attempt_id, :agent_id, :execution_id

      def self.capture(change, persistence:, kind:, manifest: nil, manifest_ref: nil)
        values = change.captured_evidence
        return unless values && values.fetch(:before).fetch(1).nil? && values.fetch(:after).fetch(1).nil?
        new(values, persistence.execution_evidence_identity, kind, manifest, manifest_ref)
      end

      def initialize(values, persistence_identity, kind, manifest, manifest_ref)
        raise ArgumentError, "Unknown dispatch kind: #{kind.inspect}" unless %i[provider tool].include?(kind)
        if kind == :provider && (!manifest || !manifest_ref)
          raise ArgumentError, "Provider dispatch evidence requires its captured manifest"
        end
        @persistence_identity = persistence_identity
        @before, @after = values.fetch(:before), values.fetch(:after)
        @execution = values.fetch(:result)
        @agent_id, @execution_id = execution.agent_id, execution.execution_id
        @journal_position = before.fetch(0).fetch(0).fetch("journal_position")
        @kind = kind
        @manifest = manifest && Phronomy::Context::LLMInputManifest.from_h(Phronomy::Values::Immutable.copy(manifest.to_h))
        @manifest_ref = manifest_ref&.dup&.freeze
        @attempt_id = SecureRandom.uuid.freeze
        freeze
      end
      private_class_method :new

      def reconcile(persistence:, original_error: nil)
        require_persistence!(persistence)
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: [agent_id])
          classify(persistence, scope)
        end
        result(disposition, original_error: original_error)
      rescue => error
        result(:unknown, original_error: original_error, read_error: error)
      end

      # Content and input preparation precede the original dispatch transaction.
      # Retry advances only its exact captured execution under a complete pre-state
      # guard; it never repeats encoding, application hooks, Policy or external work.
      def retry(persistence:, original_error: nil)
        require_persistence!(persistence)
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: [agent_id])
          current = classify(persistence, scope)
          next current unless current == :not_committed
          persistence.participate(scope) do |records|
            records.executions.save(execution_id,
              expected_revision: before.fetch(0).fetch(1).fetch("execution_revision"), execution: execution)
          end
          unless classify(persistence, scope) == :committed
            raise Phronomy::Persistence::StateConflictError, "Retried dispatch state differs from its captured proof"
          end
          :committed
        end
        result(disposition, original_error: original_error)
      rescue => error
        reconcile(persistence: persistence, original_error: error)
      end

      private

      def require_persistence!(persistence)
        return if persistence.execution_evidence_identity.equal?(@persistence_identity)
        raise Phronomy::Persistence::StateConflictError, "Dispatch evidence belongs to another Store"
      end

      def require_outer_scope!(scope)
        return if scope.outermost?
        raise Phronomy::Persistence::TransactionError, "Dispatch evidence requires its own outer transaction"
      end

      def classify(persistence, scope)
        snapshot = [ExecutionChange.read_agent_evidence(store: persistence,
          agent_id: agent_id, execution_id: execution_id,
          journal_position: @journal_position, scope: scope), nil]
        head = persistence.participate(scope) { |records| records.journals.head(agent_id) }
        return :unknown unless head == snapshot.fetch(0).fetch(0).fetch("journal_position")
        Phronomy::Persistence::SaveOutcome.compare(before: before, after: after) { snapshot }.disposition
      end

      def result(disposition, original_error:, read_error: nil)
        Result.new(disposition: disposition, evidence: self,
          original_error: original_error, read_error: read_error)
      end
    end
  end
end
