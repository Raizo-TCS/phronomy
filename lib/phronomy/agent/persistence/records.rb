# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Storage implementation of Agent's own record operations.
      # @api private
      class Records
        attr_reader :contents, :agents, :journals, :executions, :handoff_states

        def initialize(view)
          @view = view
          @contents = Phronomy::Persistence::ContentRepository.new(Phronomy::ContentStore::StoredContents.new(view))
          @agents = AgentRepository.new(view)
          @journals = JournalRepository.new(view)
          @executions = ExecutionRepository.new(view)
          @handoff_states = HandoffStateRepository.new(view)
        end

        def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
          Watermark.new(@view).check!(agent_id: agent_id, agent_revision: agent_revision, journal_position: journal_position)
        end

        def guard_agent!(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: StorageSchema::ROOTS, key: agent_id)], conditions: [])
          end
        end
      end
    end
  end
end
