# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Assigns domain sequence numbers and validates opaque stream entries.
      # @api private
      class JournalRepository
        def initialize(view) = @view = view

        def append(agent_id, expected_position:, records:)
          Phronomy::Persistence::StorageBoundary.call do
            expected = Integer(expected_position)
            entries = Array(records).each_with_index.map do |record, index|
              unless record.agent_id.to_s == agent_id.to_s
                raise Phronomy::Storage::SerializationError, "Journal record Agent mismatch"
              end
              sequenced = record.with_sequence(expected + index + 1)
              Phronomy::Storage::Entry::Append.new(id: sequenced.record_id.to_s, record: Codec.encode_journal_record(sequenced))
            end
            @view.atomic do |bound|
              stored = bound.streams(StorageSchema::JOURNAL).append(stream: agent_id.to_s,
                expected_head: expected, entries: entries)
              decode(stored, agent_id, after: expected)
            end
          end
        end

        def read(agent_id, after: nil, limit: nil)
          Phronomy::Persistence::StorageBoundary.call do
            position = after.nil? ? 0 : Integer(after)
            count = limit.nil? ? nil : Integer(limit)
            @view.atomic do |bound|
              stored = (count == 0) ? [] : bound.streams(StorageSchema::JOURNAL).read(stream: agent_id.to_s, after: position, limit: count)
              decode(stored, agent_id, after: position)
            end
          end
        end

        def head(agent_id)
          Phronomy::Persistence::StorageBoundary.call { @view.streams(StorageSchema::JOURNAL).head(stream: agent_id.to_s) }
        end

        def delete(agent_id)
          Phronomy::Persistence::StorageBoundary.call { @view.streams(StorageSchema::JOURNAL).delete(stream: agent_id.to_s) }
        end

        private

        def decode(entries, agent_id, after:)
          entries.each_with_index.map do |entry, index|
            record = Codec.decode_journal_record(entry.record)
            unless record.agent_id == agent_id.to_s && record.record_id == entry.id &&
                record.sequence == entry.position && entry.position == after + index + 1
              raise Phronomy::Storage::SerializationError, "backend returned another Journal identity/sequence"
            end
            record
          end.freeze
        end
      end
    end
  end
end
