# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Storage implementation of Team's own record operations.
      # @api private
      class Records
        attr_reader :contents, :teams, :team_executions, :handoff_states

        def initialize(view)
          @view = view
          @contents = Phronomy::Persistence::ContentRepository.new(Phronomy::ContentStore::StoredContents.new(view))
          @teams = TeamRepository.new(view)
          @team_executions = TeamExecutionRepository.new(view)
          @handoff_states = HandoffStateRepository.new(view)
        end

        def guard_team!(team_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: Phronomy::MultiAgent::Persistence::StorageSchema::ROOTS, key: team_id)], conditions: [])
          end
        end
      end
    end
  end
end
