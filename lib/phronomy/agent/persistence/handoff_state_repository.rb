# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Owns Handoff state encoding and the initial revision.
      # @api private
      class HandoffStateRepository
        def initialize(view) = @view = view

        def load(main_agent_id)
          @view.atomic do |bound|
            entry = bound.records(StorageSchema::HANDOFF_STATES).read(main_agent_id.to_s)
            entry && decode(entry, main_agent_id)
          end
        end

        def save(main_agent_id, expected_revision:, state:)
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          revision = expected.nil? ? 1 : expected + 1
          unless state.main_agent_id == main_agent_id.to_s && state.handoff_revision == revision
            raise Phronomy::Storage::SerializationError, "Handoff identity/revision mismatch"
          end
          record = Codec.encode_handoff_state(state)
          @view.atomic do |bound|
            records = bound.records(StorageSchema::HANDOFF_STATES)
            values = {key: main_agent_id.to_s, attributes: {active_agent_id: state.active_agent_id}, record: record}
            entry = if expected.nil?
              records.insert(**values, revision: revision)
            else
              records.replace(**values, expected_revision: expected, next_revision: revision)
            end
            decode(entry, main_agent_id, revision: revision)
          end
        rescue Phronomy::Storage::NotFoundError => error
          raise Phronomy::Storage::ConflictError, error.message
        end

        def delete(main_agent_id, expected_revision:)
          @view.records(StorageSchema::HANDOFF_STATES).delete(key: main_agent_id.to_s, expected_revision: Integer(expected_revision))
        end

        private

        def decode(entry, main_agent_id, revision: nil)
          state = Codec.decode_handoff_state(entry.record)
          valid = entry.key == main_agent_id.to_s && state.main_agent_id == entry.key &&
            state.handoff_revision == entry.revision && (!revision || revision == entry.revision) &&
            entry.attributes == {active_agent_id: state.active_agent_id}
          unless valid
            raise Phronomy::Storage::SerializationError, "backend returned another Handoff identity/revision"
          end
          state
        end
      end
    end
  end
end
