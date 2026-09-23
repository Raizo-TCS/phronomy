# frozen_string_literal: true

module Phronomy
  module PersistenceComposition
    # Assemble domain repositories over one raw backend or transaction view.
    # @api private
    class Repositories
      attr_reader :contents

      def initialize(view)
        @view = view
        @contents = Phronomy::ContentStore::StoredContents.new(view)
        @domain_repositories = {}
        @repository_lock = Mutex.new
      end

      def agents
        domain_repository(:agents) do
          Phronomy::Agent::Persistence::AgentRepository.new(@view)
        end
      end

      def journals
        domain_repository(:journals) do
          Phronomy::Agent::Persistence::JournalRepository.new(@view)
        end
      end

      def executions
        domain_repository(:executions) do
          Phronomy::Agent::Persistence::ExecutionRepository.new(@view)
        end
      end

      def workflow_states
        domain_repository(:workflow_states) do
          Phronomy::Workflow::Persistence::StateRepository.new(@view)
        end
      end

      def handoff_states
        domain_repository(:handoff_states) do
          Phronomy::Agent::Persistence::HandoffStateRepository.new(@view)
        end
      end

      def teams
        domain_repository(:teams) do
          Phronomy::MultiAgent::Persistence::TeamRepository.new(@view)
        end
      end

      def team_executions
        domain_repository(:team_executions) do
          Phronomy::MultiAgent::Persistence::TeamExecutionRepository.new(@view)
        end
      end

      def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
        Phronomy::Agent::Persistence::Watermark.new(@view).check!(
          agent_id: agent_id.to_s,
          agent_revision: Integer(agent_revision),
          journal_position: Integer(journal_position)
        )
      end

      private

      # Cache one wrapper per view without loading unused domain implementations.
      def domain_repository(name)
        @repository_lock.synchronize do
          @domain_repositories.fetch(name) { @domain_repositories[name] = yield }
        end
      end
    end
  end
end
