# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class AgentRepository
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create(root)
          record = Codec.encode_agent_root(root)
          stored = @backend_repository.create(
            agent_id: root.agent_id.to_s,
            agent_revision: Integer(root.agent_revision),
            record: record
          )
          decode_for_agent(stored, root.agent_id, revision: root.agent_revision)
        end

        def load(agent_id)
          decode_for_agent(@backend_repository.load(agent_id.to_s), agent_id)
        end

        def save(agent_id, expected_revision:, root:)
          expected = Integer(expected_revision)
          next_revision = Integer(root.agent_revision)
          unless next_revision == expected + 1
            raise Phronomy::Storage::ConflictError,
              "agent save must advance revision exactly once: " \
              "expected #{expected + 1}, got #{next_revision}"
          end
          unless root.agent_id.to_s == agent_id.to_s
            raise Phronomy::Storage::SerializationError,
              "Agent root identity mismatch: #{root.agent_id} != #{agent_id}"
          end

          record = Codec.encode_agent_root(root)
          stored = @backend_repository.save(
            agent_id.to_s,
            expected_revision: expected,
            next_revision: next_revision,
            record: record
          )
          decode_for_agent(stored, agent_id, revision: next_revision)
        end

        def delete(agent_id)
          @backend_repository.delete(agent_id.to_s)
        end

        private

        def decode_for_agent(record, agent_id, revision: nil)
          root = Codec.decode_agent_root(record)
          unless root.agent_id == agent_id.to_s
            raise Phronomy::Storage::SerializationError,
              "backend returned Agent root for #{root.agent_id.inspect}; expected #{agent_id.to_s.inspect}"
          end
          if revision && root.agent_revision != revision
            raise Phronomy::Storage::SerializationError,
              "backend returned Agent revision #{root.agent_revision}; expected #{revision}"
          end
          root
        end
      end
    end
  end
end
