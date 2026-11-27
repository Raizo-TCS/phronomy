# frozen_string_literal: true

module Phronomy
  module Agent
    # Exact staged records and content before fallible transcript hydration.
    # This is not a complete semantic outcome or permission to replay preparation.
    # Only transcript hydration is repeatable; complete input construction is single-use.
    # @api private
    class OutcomePreparation
      class ReadContents < Phronomy::ContentStore::Base
        def initialize(contents, writes)
          @contents = contents
          @writes = writes.to_h { |write| [write.reference, write.bytes] }
        end

        def fetch(reference)
          value = @writes.fetch(reference) { @contents.fetch(reference) }
          unless content_id_for(value) == reference
            raise Phronomy::ContentStore::IntegrityError, "Prepared transcript content digest mismatch: #{reference}"
          end
          value.dup
        end
      end
      private_constant :ReadContents

      def initialize(values, writes, journal_records:, persistence:, participant:)
        if values.fetch(:result).type == :completed && journal_records.nil?
          raise ArgumentError, "Completed outcome preparation requires captured transcript records"
        end
        @values = {before: Phronomy::Values::Immutable.copy(values.fetch(:before)),
                   after: Phronomy::Values::Immutable.copy(values.fetch(:after)),
                   result: values.fetch(:result)}.freeze
        @writes = writes.dup.freeze
        @journal_records = journal_records&.dup&.freeze
        @identity, @participant = persistence.execution_evidence_identity, participant
        @materialized = {}
        @mutex = Mutex.new
        freeze
      end

      def materialize(persistence:)
        unless persistence.execution_evidence_identity.equal?(@identity)
          raise Phronomy::Persistence::StateConflictError, "Agent outcome preparation belongs to another Store"
        end
        @mutex.synchronize do
          # Keep complete input construction single-use, including failures,
          # after successful transcript hydration. Never retain the fresh content
          # port or its transaction-local views.
          @materialized[:outcome] ||= materialize_outcome(persistence)
          return @materialized[:input] if @materialized[:input]
          raise @materialized[:input_error] if @materialized[:input_error]
          if @materialized[:input_attempted]
            raise Phronomy::Error, "Agent outcome input construction did not complete"
          end
          @materialized[:input_attempted] = true
          begin
            @materialized[:input] = TerminalPersistenceEvidence::CapturedInput.new(
              @values.merge(result: @materialized.fetch(:outcome)), @writes,
              persistence: persistence, participant: @participant
            )
          rescue Exception => error # rubocop:disable Lint/RescueException
            @materialized[:input_error] = error
            raise
          end
        end
      end

      private

      def materialize_outcome(persistence)
        outcome = @values.fetch(:result)
        return outcome unless @journal_records
        contents = ReadContents.new(persistence.contents, @writes)
        view = OutcomeWritePlan::ContentView.new(contents: contents)
        messages = RuntimeInput.new(agent: nil, persistence: view)
          .materialize_transcript(root: outcome.root, records: @journal_records)
        outcome.with(result: outcome.result.merge(messages: messages).freeze)
      end
    end
  end
end
