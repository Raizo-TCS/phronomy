# frozen_string_literal: true

module Phronomy
  module Agent
    # Selects Handoff persistence; execution ownership and delivery remain in
    # ExecutionCoordinator. This is not a public subclass extension contract.
    class HandoffExecutionCoordinator < Phronomy::Agent::ExecutionCoordinator
      private

      def build_outcome_committer
        HandoffOutcomeCommitter.new(agent: @agent, persistence: @agent.persistence)
      end
    end
  end
end
