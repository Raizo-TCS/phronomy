# frozen_string_literal: true

require_relative "../persistence/errors"

module Phronomy
  module MultiAgent
    # Describes the Team itself, not a child Agent.
    # @api public
    class TeamNotFoundError < Phronomy::Persistence::NotFoundError
      attr_reader :team_id

      def initialize(message = nil, team_id:)
        @team_id = team_id.to_s.dup.freeze
        super(message || "Team #{@team_id}: not_found", code: "team.not_found")
      end
    end
  end
end
