# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Owns Team root encoding and validates returned storage metadata.
      # @api private
      class TeamRepository
        def initialize(view) = @view = view

        def create(root)
          record = Codec.encode_team_root(root)
          @view.atomic do |bound|
            entry = bound.records(Phronomy::TeamStorageSchema::ROOTS).insert(key: root.team_id.to_s,
              revision: Integer(root.team_revision), attributes: {}, record: record)
            decode(entry, root.team_id, revision: root.team_revision)
          end
        end

        def load(team_id)
          value = @view.atomic do |bound|
            entry = bound.records(Phronomy::TeamStorageSchema::ROOTS).read(team_id.to_s)
            entry && decode(entry, team_id)
          end
          value || raise(Phronomy::Storage::NotFoundError, "Team not found: #{team_id}")
        end

        def save(team_id, expected_revision:, root:)
          expected = Integer(expected_revision)
          revision = Integer(root.team_revision)
          raise Phronomy::Storage::ConflictError, "root save must advance revision exactly once" unless revision == expected + 1
          unless root.team_id.to_s == team_id.to_s
            raise Phronomy::Storage::SerializationError, "Team root identity mismatch"
          end
          record = Codec.encode_team_root(root)
          @view.atomic do |bound|
            entry = bound.records(Phronomy::TeamStorageSchema::ROOTS).replace(key: team_id.to_s,
              expected_revision: expected, next_revision: revision, attributes: {}, record: record)
            decode(entry, team_id, revision: revision)
          end
        end

        def delete(team_id)
          @view.records(Phronomy::TeamStorageSchema::ROOTS).delete(key: team_id.to_s)
        end

        private

        def decode(entry, team_id, revision: nil)
          root = Codec.decode_team_root(entry.record)
          valid = entry.key == team_id.to_s && root.team_id == entry.key &&
            root.team_revision == entry.revision && (!revision || revision == entry.revision)
          unless valid
            raise Phronomy::Storage::SerializationError, "backend returned another Team identity/revision"
          end
          root
        end
      end
    end
  end
end
