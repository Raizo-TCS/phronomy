# frozen_string_literal: true

module Phronomy
  module Storage
    # Record-oriented repositories sharing one storage consistency view.
    # SQL backends bind all eight repositories and the watermark to the same
    # checked-out connection. This object performs no domain conversion.
    # @api public
    class Repositories
      # @api public
      attr_reader :contents, :agents, :journals, :executions, :workflow_states,
        :handoff_states, :teams, :team_executions

      # @api public
      def initialize(contents:, agents:, journals:, executions:, workflow_states:,
        handoff_states:, teams:, team_executions:, watermark:)
        @contents = contents
        @agents = agents
        @journals = journals
        @executions = executions
        @workflow_states = workflow_states
        @handoff_states = handoff_states
        @teams = teams
        @team_executions = team_executions
        @watermark = watermark
      end

      # Checks the stored revision and journal position in this view.
      # @api public
      def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
        @watermark.assert_agent_watermark!(
          agent_id: agent_id,
          agent_revision: agent_revision,
          journal_position: journal_position
        )
      end
    end
  end
end
