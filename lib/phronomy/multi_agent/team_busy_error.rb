# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module MultiAgent
    # Describes the Team itself, not a child Agent.
    # @api public
    class TeamBusyError < Phronomy::Error
      attr_reader :team_id

      def initialize(message = nil, team_id:)
        @team_id = team_id.to_s.dup.freeze
        super(message || "Team #{@team_id}: busy", code: "team.busy")
      end
    end
  end
end
