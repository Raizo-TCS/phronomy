# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class HandoffStateRepository
        def initialize(backend_repository) = @backend_repository = backend_repository

        def load(main_agent_id)
          record = @backend_repository.load(main_agent_id.to_s)
          record && decode(record, main_agent_id)
        end

        def save(main_agent_id, expected_revision:, state:)
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          next_revision = expected.nil? ? 1 : expected + 1
          unless state.main_agent_id == main_agent_id.to_s && state.handoff_revision == next_revision
            raise Phronomy::Storage::SerializationError, "Handoff identity/revision mismatch"
          end
          record = @backend_repository.save(main_agent_id.to_s,
            expected_revision: expected, next_revision: next_revision,
            active_agent_id: state.active_agent_id, record: Codec.encode_handoff_state(state))
          decode(record, main_agent_id, revision: next_revision)
        end

        def delete(main_agent_id, expected_revision:)
          @backend_repository.delete(main_agent_id.to_s, expected_revision: Integer(expected_revision))
        end

        private

        def decode(record, main_agent_id, revision: nil)
          state = Codec.decode_handoff_state(record)
          identity_matches = state.main_agent_id == main_agent_id.to_s
          revision_matches = revision.nil? || state.handoff_revision == revision
          unless identity_matches && revision_matches
            raise Phronomy::Storage::SerializationError, "Backend returned another Handoff identity/revision"
          end
          state
        end
      end
    end
  end
end
