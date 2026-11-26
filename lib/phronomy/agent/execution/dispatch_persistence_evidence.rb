# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Detached proof of one bounded pre-dispatch execution change. The proof
    # does not authorize external dispatch or retain live Agent/participant state.
    # Only the original Store may compare or repeat the captured execution save,
    # after the prior backend attempt has settled and authoritative reads apply.
    # @api private
    class DispatchPersistenceEvidence
      Result = Data.define(:disposition, :evidence, :original_error, :read_error, :continuation_error) do
        def initialize(disposition:, evidence:, original_error:, read_error:, continuation_error: nil)
          super
        end
      end

      attr_reader :before, :after, :execution, :kind, :manifest, :manifest_ref,
        :attempt_id, :agent_id, :execution_id

      def self.capture(change, persistence:, kind:, manifest: nil, manifest_ref: nil, participant: nil)
        values = change.captured_evidence
        return unless values
        participation = if participant&.respond_to?(:capture_dispatch_recovery, true)
          participant.__send__(:capture_dispatch_recovery, values: values, persistence: persistence)
        end
        participant_free = values.fetch(:before).fetch(1).nil? && values.fetch(:after).fetch(1).nil?
        return unless participation || participant_free
        new(values, persistence.execution_evidence_identity, kind, manifest, manifest_ref, participation)
      end

      def initialize(values, persistence_identity, kind, manifest, manifest_ref, participation)
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
        @participation = participation
        @manifest = manifest && Phronomy::Context::LLMInputManifest.from_h(Phronomy::Values::Immutable.copy(manifest.to_h))
        @manifest_ref = manifest_ref&.dup&.freeze
        @attempt_id = SecureRandom.uuid.freeze
        freeze
      end
      private_class_method :new

      def participation? = !@participation.nil?

      def reconcile(persistence:, original_error: nil)
        require_persistence!(persistence)
        continuation_error = nil
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: guarded_agent_ids(persistence, scope))
          classify(persistence, scope).tap do |current|
            continuation_error = continuation_error_in(persistence, scope) if current == :committed
          end
        end
        result(disposition, original_error: original_error, continuation_error: continuation_error)
      rescue => error
        result(:unknown, original_error: original_error, read_error: error)
      end

      # Input preparation precedes the original dispatch transaction. An opt-in
      # domain may also restore its captured opaque content and retention writes.
      # Retry never repeats encoding, application hooks, Policy or external work.
      def retry(persistence:, original_error: nil)
        require_persistence!(persistence)
        continuation_error = retry_error = nil
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: guarded_agent_ids(persistence, scope))
          current = classify(persistence, scope)
          if current != :not_committed
            continuation_error = continuation_error_in(persistence, scope) if current == :committed
            next current
          end
          begin
            @participation&.assert_retryable!(persistence: persistence, scope: scope)
          rescue => error
            retry_error = error
            next :not_committed
          end
          @participation&.replay(persistence: persistence, scope: scope)
          persistence.participate(scope) do |records|
            records.executions.save(execution_id,
              expected_revision: before.fetch(0).fetch(1).fetch("execution_revision"), execution: execution)
          end
          unless classify(persistence, scope) == :committed
            raise Phronomy::Persistence::StateConflictError, "Retried dispatch state differs from its captured proof"
          end
          continuation_error = continuation_error_in(persistence, scope)
          :committed
        end
        result(disposition, original_error: original_error, read_error: retry_error,
          continuation_error: continuation_error)
      rescue => error
        reconcile(persistence: persistence, original_error: error)
      end

      private

      def guarded_agent_ids(persistence, scope)
        @participation ? @participation.guarded_agent_ids(persistence: persistence, scope: scope) : [agent_id]
      end

      # A committed barrier is historical fact. Fresh domain authority is a
      # separate condition for granting its still-unused continuation right.
      def continuation_error_in(persistence, scope)
        @participation&.assert_continuable!(persistence: persistence, scope: scope)
        nil
      rescue => error
        error
      end

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
          journal_position: @journal_position, scope: scope),
          @participation&.read(persistence: persistence, scope: scope)]
        head = persistence.participate(scope) { |records| records.journals.head(agent_id) }
        return :unknown unless head == snapshot.fetch(0).fetch(0).fetch("journal_position")
        Phronomy::Persistence::SaveOutcome.compare(before: before, after: after) { snapshot }.disposition
      end

      def result(disposition, original_error:, read_error: nil, continuation_error: nil)
        Result.new(disposition: disposition, evidence: self,
          original_error: original_error, read_error: read_error, continuation_error: continuation_error)
      end
    end
  end
end
