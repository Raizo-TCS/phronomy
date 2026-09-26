# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Agent revision and journal position form one guarded domain watermark.
      # @api private
      class Watermark
        def initialize(view) = @view = view

        def check!(agent_id:, agent_revision:, journal_position:)
          Phronomy::Persistence::StorageBoundary.call do
            key = agent_id.to_s
            @view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: StorageSchema::ROOTS, key: key)],
              conditions: [
                Phronomy::Storage::Condition::RevisionIs.new(resource: StorageSchema::ROOTS,
                  key: key, expected: Integer(agent_revision)),
                Phronomy::Storage::Condition::StreamHeadIs.new(resource: StorageSchema::JOURNAL,
                  stream: key, expected: Integer(journal_position))
              ])
          rescue Phronomy::Storage::ConditionFailedError => error
            label = error.condition.is_a?(Phronomy::Storage::Condition::RevisionIs) ? "agent revision" : "journal position"
            raise Phronomy::Storage::ConflictError, "#{label} conflict"
          end
        end
      end
    end
  end
end
