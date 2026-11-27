# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Opt-in, process-local proof for captured Agent outcome writes. Standalone
    # terminal facts and native final/wait outcomes share exact persistence replay.
    # This value owns neither the original observer nor the live execution.
    # The caller must retain it and use the original Persistence only after the
    # previous backend transaction has settled and authoritative reads apply.
    # Native writes include only the captured parent extension and retention
    # changes. Later child progress does not invalidate a committed parent fact.
    # @api private
    class TerminalPersistenceEvidence
      ContentWrite = Data.define(:reference, :bytes, :canonicalization_version)
      Outcome = Data.define(:type, :execution, :root, :appended_records, :result, :error_diagnostic, :approval_request, :execution_observation)
      Result = Data.define(:disposition, :evidence, :original_error, :read_error)

      # Complete intended values survive a failed proof constructor. Rebuilding
      # this proof uses the native read-only evidence adapter and writes nothing.
      # It does not rerun participant commit, encoding or output validation.
      class CapturedInput
        attr_reader :values

        def initialize(values, writes, persistence:, participant:)
          @values = {before: Phronomy::Values::Immutable.copy(values.fetch(:before)),
                     after: Phronomy::Values::Immutable.copy(values.fetch(:after)),
                     result: values.fetch(:result)}.freeze
          @writes = writes.dup.freeze
          @outcome = TerminalPersistenceEvidence.detached_outcome(@values, @writes)
          @identity, @participant = persistence.execution_evidence_identity, participant
          freeze
        end

        def materialize(persistence:)
          unless persistence.execution_evidence_identity.equal?(@identity)
            raise Phronomy::Persistence::StateConflictError, "Agent outcome proposal belongs to another Store"
          end
          TerminalPersistenceEvidence.capture_values(@values, @writes, persistence: persistence,
            participant: @participant, outcome: @outcome)
        end
      end

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

      # Decode only already captured bytes, using the ordinary content format.
      # Missing input cannot be replaced by a new read or a live domain value.
      class CapturedContents < Phronomy::ContentStore::Base
        def initialize(writes)
          @writes = writes
        end

        def fetch(reference)
          write = @writes.find { |candidate| candidate.reference == reference }
          unless write
            raise Phronomy::ContentStore::IntegrityError, "Agent outcome observation has no captured content: #{reference}"
          end
          write.bytes.dup
        end
      end
      private_constant :RecordingContents, :RecordingScope, :CapturedContents

      attr_reader :before, :after, :outcome, :content_writes, :attempt_id, :agent_id, :execution_id

      def self.recording_scope(records, writes)
        RecordingScope.new(contents: RecordingContents.new(records.contents, writes),
          agents: records.agents, executions: records.executions, journals: records.journals)
      end

      def self.capture(change, writes, persistence:, participant: nil)
        values = change.captured_evidence
        return unless values
        capture_values(values, writes, persistence: persistence, participant: participant)
      end

      def self.capture_values(values, writes, persistence:, participant: nil, outcome: nil)
        participation = if participant&.respond_to?(:capture_outcome_recovery, true)
          participant.__send__(:capture_outcome_recovery, values: values, persistence: persistence)
        end
        intended = values.fetch(:result)
        native_wait = participation && %i[coordination_wait suspended].include?(intended.type)
        return unless intended.execution.terminal? || native_wait
        participant_free = values.fetch(:before).fetch(1).nil? && values.fetch(:after).fetch(1).nil?
        return unless participation || participant_free
        new(values, writes, persistence.execution_evidence_identity, participation, outcome: outcome)
      end

      def self.detached_outcome(values, writes)
        intended = values.fetch(:result)
        execution = intended.execution
        observation = if execution.terminal?
          contents = CapturedContents.new(writes)
          result = if execution.result_ref
            (execution.metadata["result_format"] == "json") ? contents.fetch_json(execution.result_ref) : contents.fetch_text(execution.result_ref)
          end
          ExecutionObservation.new(agent_id: execution.agent_id, execution_id: execution.execution_id,
            status: execution.status, result: result,
            raw_output: execution.metadata["raw_output_ref"] && contents.fetch_text(execution.metadata.fetch("raw_output_ref")),
            error: execution.error_ref && contents.fetch_json(execution.error_ref),
            reservation: execution.metadata["reservation"] && ReservedExecution.new(agent_id: execution.agent_id,
              execution_id: execution.execution_id, correlation: execution.metadata["reservation"]),
            transfer_receipt: nil, cancellation_requested: execution.metadata["cancellation_requested"] == true || values.fetch(:after).fetch(0).fetch(4) == true)
        end
        Outcome.new(type: intended.type, execution: intended.execution,
          root: intended.root, appended_records: intended.appended_records.dup.freeze,
          result: Phronomy::Values::Immutable.copy(intended.result),
          error_diagnostic: observation ? observation.error : intended.error && Phronomy::Values::Immutable.copy(Phronomy::Error.diagnostic(intended.error)),
          approval_request: intended.approval_request && Phronomy::Values::Immutable.copy(intended.approval_request.to_h),
          execution_observation: observation)
      end

      def initialize(values, writes, persistence_identity, participation, outcome: nil)
        @persistence_identity, @participation = persistence_identity, participation
        @before, @after = values.fetch(:before), values.fetch(:after)
        intended = values.fetch(:result)
        @agent_id = intended.execution.agent_id
        @execution_id = intended.execution.execution_id
        @journal_position = before.fetch(0).fetch(0).fetch("journal_position")
        @outcome = outcome || self.class.detached_outcome(values, writes)
        @content_writes = writes.dup.freeze
        @attempt_id = SecureRandom.uuid.freeze
        freeze
      end
      private_class_method :new

      def reconcile(persistence:, original_error: nil)
        require_persistence!(persistence)
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: guarded_agent_ids(persistence, scope))
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
        retry_error = nil
        disposition = persistence.coordinator.atomic do |scope|
          require_outer_scope!(scope)
          persistence.guard_agents(scope, agent_ids: guarded_agent_ids(persistence, scope))
          current = classify(persistence, scope)
          next current unless current == :not_committed
          begin
            @participation&.assert_retryable!(persistence: persistence, scope: scope)
          rescue => error
            retry_error = error
            next :not_committed
          end
          @participation&.replay(persistence: persistence, scope: scope)
          persistence.participate(scope) { |records| replay(records) }
          unless classify(persistence, scope) == :committed
            raise Phronomy::Persistence::StateConflictError, "Retried Agent terminal state differs from its captured proof"
          end
          :committed
        end
        result(disposition, original_error: original_error, read_error: retry_error)
      rescue => error
        # The retry uses the same intended bytes and record identities; another
        # lost response therefore remains classifiable against this same proof.
        reconcile(persistence: persistence, original_error: error)
      end

      private

      # The native caller owns the real outer transaction and ordered guards.
      # Compare the staged pre-state before applying the exact captured writes.
      # Initial native planning already made the domain decision under those
      # guards; later retry separately rechecks current continuation authority.
      def apply_prepared_in(persistence:, scope:)
        require_persistence!(persistence)
        require_outer_scope!(scope)
        unless classify(persistence, scope) == :not_committed
          raise Phronomy::Persistence::StateConflictError, "Prepared Agent outcome no longer matches its pre-state"
        end
        @participation&.replay(persistence: persistence, scope: scope)
        persistence.participate(scope) { |records| replay(records) }
        unless classify(persistence, scope) == :committed
          raise Phronomy::Persistence::StateConflictError, "Prepared Agent outcome differs from its intended state"
        end
        nil
      end

      def guarded_agent_ids(persistence, scope)
        @participation ? @participation.guarded_agent_ids(persistence: persistence, scope: scope) : [agent_id]
      end

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
          journal_position: @journal_position, scope: scope),
          @participation&.read(persistence: persistence, scope: scope)]
        head = persistence.participate(scope) { |records| records.journals.head(agent_id) }
        return :unknown unless head == snapshot.fetch(0).fetch(0).fetch("journal_position")
        disposition = Phronomy::Persistence::SaveOutcome.compare(before: before, after: after) { snapshot }.disposition
        if disposition == :committed
          @participation&.assert_content!(persistence: persistence, scope: scope)
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
        unless outcome.appended_records.empty?
          records.journals.append(agent_id, expected_position: @journal_position, records: outcome.appended_records)
        end
        records.executions.save(execution_id,
          expected_revision: before.fetch(0).fetch(1).fetch("execution_revision"), execution: outcome.execution)
        unless outcome.root.to_h == before.fetch(0).fetch(0)
          records.agents.save(agent_id,
            expected_revision: before.fetch(0).fetch(0).fetch("agent_revision"), root: outcome.root)
        end
      end

      def result(disposition, original_error: nil, read_error: nil)
        Result.new(disposition: disposition, evidence: self,
          original_error: original_error, read_error: read_error)
      end
    end
  end
end
