# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Opt-in, process-local proof for one installed standalone terminal write.
    # This value owns neither the original observer nor the live execution.
    # The caller must retain it and use the original Persistence only after the
    # previous backend transaction has settled and authoritative reads apply.
    # @api private
    class TerminalPersistenceEvidence
      ContentWrite = Data.define(:reference, :bytes, :canonicalization_version)
      Outcome = Data.define(:type, :execution, :root, :appended_records, :result, :error_diagnostic)
      Result = Data.define(:disposition, :evidence, :original_error, :read_error)

      # Transaction-local recorder; only detached ContentWrite values escape.
      class RecordingContents < Phronomy::ContentStore::Base
        def initialize(contents, writes)
          @contents, @writes = contents, writes
        end

        def put(bytes, canonicalization_version:)
          value = String(bytes).b.dup.freeze
          version = Integer(canonicalization_version)
          reference = @contents.put(value, canonicalization_version: version)
          @writes << ContentWrite.new(reference: reference.to_s.dup.freeze,
            bytes: value, canonicalization_version: version)
          reference
        end

        def fetch(reference) = @contents.fetch(reference)
        def exist?(reference) = @contents.exist?(reference)
      end

      RecordingScope = Data.define(:contents, :agents, :executions, :journals)
      private_constant :RecordingContents, :RecordingScope

      attr_reader :before, :after, :outcome, :content_writes, :attempt_id, :agent_id, :execution_id

      def self.recording_scope(records, writes)
        RecordingScope.new(contents: RecordingContents.new(records.contents, writes),
          agents: records.agents, executions: records.executions, journals: records.journals)
      end

      def self.capture(change, writes, persistence:)
        values = change.captured_evidence
        return unless values && values[:result].execution.terminal?
        new(values, writes, persistence.execution_evidence_identity)
      end

      def initialize(values, writes, persistence_identity)
        @persistence_identity = persistence_identity
        @before, @after = values.fetch(:before), values.fetch(:after)
        intended = values.fetch(:result)
        @agent_id = intended.execution.agent_id
        @execution_id = intended.execution.execution_id
        @journal_position = before.fetch(0).fetch(0).fetch("journal_position")
        @outcome = Outcome.new(type: intended.type, execution: intended.execution,
          root: intended.root, appended_records: intended.appended_records.dup.freeze,
          result: Phronomy::Values::Immutable.copy(intended.result),
          error_diagnostic: intended.error && Phronomy::Values::Immutable.copy(Phronomy::Error.diagnostic(intended.error)))
        @content_writes = writes.dup.freeze
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

      # This repeats only the already encoded persistence writes. It never
      # reconstructs a terminal transition or invokes domain/provider callbacks.
      def retry(persistence:, original_error: nil)
        require_persistence!(persistence)
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: [agent_id])
          current = classify(persistence, scope)
          next current unless current == :not_committed
          persistence.participate(scope) { |records| replay(records) }
          unless classify(persistence, scope) == :committed
            raise Phronomy::Persistence::StateConflictError, "Retried Agent terminal state differs from its captured proof"
          end
          :committed
        end
        result(disposition, original_error: original_error)
      rescue => error
        # The retry uses the same intended bytes and record identities; another
        # lost response therefore remains classifiable against this same proof.
        reconcile(persistence: persistence, original_error: error)
      end

      private

      def require_persistence!(persistence)
        return if persistence.execution_evidence_identity.equal?(@persistence_identity)
        raise Phronomy::Persistence::StateConflictError, "Agent terminal evidence belongs to another Store"
      end

      def require_outer_scope!(scope)
        return if scope.outermost?
        raise Phronomy::Persistence::TransactionError, "Agent terminal evidence requires its own outer transaction"
      end

      def classify(persistence, scope)
        snapshot = [ExecutionChange.read_agent_evidence(store: persistence,
          agent_id: agent_id, execution_id: execution_id,
          journal_position: @journal_position, scope: scope), nil]
        head = persistence.participate(scope) { |records| records.journals.head(agent_id) }
        return :unknown unless head == snapshot.fetch(0).fetch(0).fetch("journal_position")
        disposition = Phronomy::Persistence::SaveOutcome.compare(before: before, after: after) { snapshot }.disposition
        if disposition == :committed
          persistence.participate(scope) do |records|
            content_writes.each do |write|
              unless records.contents.fetch(write.reference) == write.bytes
                raise Phronomy::ContentStore::IntegrityError, "Agent terminal content differs from its captured bytes"
              end
            end
          end
        end
        disposition
      end

      def replay(records)
        content_writes.each do |write|
          reference = records.contents.put(write.bytes, canonicalization_version: write.canonicalization_version)
          unless reference == write.reference
            raise Phronomy::ContentStore::IntegrityError, "Agent terminal content reference changed during retry"
          end
        end
        records.journals.append(agent_id, expected_position: @journal_position, records: outcome.appended_records)
        records.executions.save(execution_id,
          expected_revision: before.fetch(0).fetch(1).fetch("execution_revision"), execution: outcome.execution)
        records.agents.save(agent_id,
          expected_revision: before.fetch(0).fetch(0).fetch("agent_revision"), root: outcome.root)
      end

      def result(disposition, original_error: nil, read_error: nil)
        Result.new(disposition: disposition, evidence: self,
          original_error: original_error, read_error: read_error)
      end
    end
  end
end
