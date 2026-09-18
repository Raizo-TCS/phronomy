# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class JournalRepository
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def append(agent_id, expected_position:, records:)
          expected = Integer(expected_position)
          sequenced = Array(records).each_with_index.map do |record, index|
            unless record.agent_id.to_s == agent_id.to_s
              raise Phronomy::Storage::SerializationError,
                "Journal record Agent mismatch: #{record.agent_id} != #{agent_id}"
            end
            record.with_sequence(expected + index + 1)
          end
          encoded = sequenced.map { |record| Codec.encode_journal_record(record) }
          stored = @backend_repository.append(
            agent_id.to_s,
            expected_position: expected,
            records: encoded,
            record_ids: sequenced.map { |record| record.record_id.to_s }.freeze
          )
          decoded = Array(stored).map { |record| Codec.decode_journal_record(record) }
          validate_read!(decoded, agent_id, start_sequence: expected + 1)
        end

        def read(agent_id, after: nil, limit: nil)
          after_value = after.nil? ? nil : Integer(after)
          limit_value = limit.nil? ? nil : Integer(limit)
          stored = @backend_repository.read(
            agent_id.to_s,
            after: after_value,
            limit: limit_value
          )
          decoded = Array(stored).map { |record| Codec.decode_journal_record(record) }
          validate_read!(decoded, agent_id, start_sequence: (after_value || 0) + 1)
        end

        def head(agent_id)
          Integer(@backend_repository.head(agent_id.to_s))
        end

        def delete(agent_id)
          @backend_repository.delete(agent_id.to_s)
        end

        private

        def validate_read!(records, agent_id, start_sequence:)
          records.each_with_index do |record, index|
            unless record.agent_id == agent_id.to_s
              raise Phronomy::Storage::SerializationError,
                "backend returned Journal record for #{record.agent_id.inspect}; expected #{agent_id.to_s.inspect}"
            end
            expected_sequence = start_sequence + index
            unless record.sequence == expected_sequence
              raise Phronomy::Storage::SerializationError,
                "backend returned Journal sequence #{record.sequence.inspect}; expected #{expected_sequence}"
            end
          end
          records.freeze
        end
      end
    end
  end
end
