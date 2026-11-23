# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module MultiAgent
    # Cancellation delivery is unresolved; this is not a cancelled Team result.
    # The exact run remains available for explicit cancel or resume recovery.
    # @api public
    class TeamCancellationDeliveryError < Phronomy::Error
      attr_reader :team_id, :team_execution_id

      def initialize(team_id:, team_execution_id:)
        @team_id = team_id.to_s.dup.freeze
        @team_execution_id = team_execution_id.to_s.dup.freeze
        super("Team #{@team_id} cancellation delivery is unresolved for run #{@team_execution_id}; " \
          "retry cancel or resume with this exact run ID", code: "team.cancellation_delivery")
      end
    end
  end
end
