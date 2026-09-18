# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Read and assemble domain results; the public entry point owns the execution-thread guard.
      # @api private
      class Queries
        def initialize(repositories)
          @repositories = repositories
        end

        def team_execution_result(team_execution_id)
          execution = @repositories.team_executions.load(team_execution_id)
          {
            team_execution_id: execution.team_execution_id, team_id: execution.team_id,
            status: execution.status, phase: execution.phase,
            result_ref: execution.result_ref, error_ref: execution.error_ref,
            result: execution.result_ref && @repositories.contents.fetch_json(execution.result_ref),
            error: execution.error_ref && @repositories.contents.fetch_json(execution.error_ref)
          }.then { |value| Phronomy::Values::Immutable.copy(value) }
        end

        def list_team_executions(team_id, after: nil, limit: 100)
          @repositories.team_executions.list(team_id, after: after, limit: limit)
        end
      end
    end
  end
end
