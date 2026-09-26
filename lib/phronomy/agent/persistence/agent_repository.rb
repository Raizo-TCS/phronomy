# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Owns Agent root encoding and validates returned storage metadata.
      # @api private
      class AgentRepository
        def initialize(view) = @view = view

        def create(root)
          Phronomy::Persistence::StorageBoundary.call do
            record = Codec.encode_agent_root(root)
            @view.atomic do |bound|
              entry = bound.records(StorageSchema::ROOTS).insert(key: root.agent_id.to_s,
                revision: Integer(root.agent_revision), attributes: {}, record: record)
              decode(entry, root.agent_id, revision: root.agent_revision)
            end
          end
        end

        def load(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            value = @view.atomic do |bound|
              entry = bound.records(StorageSchema::ROOTS).read(agent_id.to_s)
              entry && decode(entry, agent_id)
            end
            value || raise(Phronomy::Storage::NotFoundError, "Agent not found: #{agent_id}")
          end
        end

        def save(agent_id, expected_revision:, root:)
          Phronomy::Persistence::StorageBoundary.call do
            expected = Integer(expected_revision)
            revision = Integer(root.agent_revision)
            raise Phronomy::Storage::ConflictError, "root save must advance revision exactly once" unless revision == expected + 1
            unless root.agent_id.to_s == agent_id.to_s
              raise Phronomy::Storage::SerializationError, "Agent root identity mismatch"
            end
            record = Codec.encode_agent_root(root)
            @view.atomic do |bound|
              entry = bound.records(StorageSchema::ROOTS).replace(key: agent_id.to_s,
                expected_revision: expected, next_revision: revision, attributes: {}, record: record)
              decode(entry, agent_id, revision: revision)
            end
          end
        end

        def delete(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.records(StorageSchema::ROOTS).delete(key: agent_id.to_s)
          end
        end

        private

        def decode(entry, agent_id, revision: nil)
          root = Codec.decode_agent_root(entry.record)
          valid = entry.key == agent_id.to_s && root.agent_id == entry.key &&
            root.agent_revision == entry.revision && (!revision || revision == entry.revision)
          unless valid
            raise Phronomy::Storage::SerializationError, "backend returned another Agent identity/revision"
          end
          root
        end
      end
    end
  end
end
