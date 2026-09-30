# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Bind reservation evidence and its stable lock to the caller's transaction.
      # The coordination operation owns the interpretation of the evidence.
      # @api private
      class Reservation
        def initialize(view) = @view = view

        def team(owner)
          guard(Phronomy::TeamStorageSchema::ROOTS, owner.fetch("team_id"))
          TeamExecutionRepository.new(@view).load(owner.fetch("team_execution_id"))
        end

        def subagent(owner)
          guard(Phronomy::Agent::Persistence::StorageSchema::ROOTS, owner.fetch("parent_agent_id"))
          Phronomy::Agent::Persistence::ExecutionRepository.new(@view).load(owner.fetch("parent_execution_id"))
        end

        def handoff(owner)
          Phronomy::Agent::Persistence::HandoffStateRepository.new(@view).load_locked(owner.fetch("main_agent_id"))
        end

        def contents
          Phronomy::Persistence::ContentRepository.new(Phronomy::ContentStore::StoredContents.new(@view))
        end

        private

        def guard(resource, key)
          @view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: resource, key: key)], conditions: [])
        end
      end
    end
  end
end
