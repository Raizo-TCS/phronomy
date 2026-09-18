# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Domain repository over a raw repository in the selected storage transaction.
      # @api private
      class TeamRepository
        def initialize(backend_repository)
          @backend_repository = backend_repository
        end

        def create(root)
          record = Codec.encode_team_root(root)
          stored = @backend_repository.create(
            team_id: root.team_id.to_s,
            team_revision: Integer(root.team_revision),
            record: record
          )
          decode_for_team(stored, root.team_id, revision: root.team_revision)
        end

        def load(team_id)
          decode_for_team(@backend_repository.load(team_id.to_s), team_id)
        end

        def save(team_id, expected_revision:, root:)
          expected = Integer(expected_revision)
          next_revision = Integer(root.team_revision)
          unless next_revision == expected + 1
            raise Phronomy::Storage::ConflictError,
              "agent save must advance revision exactly once: " \
              "expected #{expected + 1}, got #{next_revision}"
          end
          unless root.team_id.to_s == team_id.to_s
            raise Phronomy::Storage::SerializationError,
              "Team root identity mismatch: #{root.team_id} != #{team_id}"
          end

          record = Codec.encode_team_root(root)
          stored = @backend_repository.save(
            team_id.to_s,
            expected_revision: expected,
            next_revision: next_revision,
            record: record
          )
          decode_for_team(stored, team_id, revision: next_revision)
        end

        def delete(team_id)
          @backend_repository.delete(team_id.to_s)
        end

        private

        def decode_for_team(record, team_id, revision: nil)
          root = Codec.decode_team_root(record)
          unless root.team_id == team_id.to_s
            raise Phronomy::Storage::SerializationError,
              "backend returned Team root for #{root.team_id.inspect}; expected #{team_id.to_s.inspect}"
          end
          if revision && root.team_revision != revision
            raise Phronomy::Storage::SerializationError,
              "backend returned Team revision #{root.team_revision}; expected #{revision}"
          end
          root
        end
      end
    end
  end
end
