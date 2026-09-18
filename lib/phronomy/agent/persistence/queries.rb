# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Read and assemble domain results; the public entry point owns the execution-thread guard.
      # @api private
      class Queries
        def initialize(repositories)
          @repositories = repositories
        end

        def execution_result(execution_id)
          execution = @repositories.executions.load(execution_id)
          {
            execution_id: execution.execution_id, agent_id: execution.agent_id,
            status: execution.status, phase: execution.phase,
            result_ref: execution.result_ref, error_ref: execution.error_ref,
            result: execution.result_ref && @repositories.contents.fetch_text(execution.result_ref),
            error: execution.error_ref && @repositories.contents.fetch_json(execution.error_ref)
          }.then { |value| Phronomy::Values::Immutable.copy(value) }
        end

        def handoff_result(execution_id, main_agent_id: nil)
          anchor = main_agent_id&.to_s
          seen = {}
          current = execution_id.to_s
          reserved_agent_id = nil
          loop do
            raise Phronomy::Storage::SerializationError, "Cyclic durable Handoff chain" if seen[current]
            seen[current] = true
            begin
              execution = @repositories.executions.load(current)
            rescue Phronomy::Storage::NotFoundError
              routing = @repositories.handoff_states.load(anchor)
              if routing && Array(routing.metadata["cancelled_execution_ids"]).include?(current)
                return {execution_id: current, agent_id: reserved_agent_id, status: :cancelled, result: nil, error: nil}.freeze
              end
              if reserved_agent_id && routing && routing.phase != "stable" && routing.pending_target_execution_id == current
                return {execution_id: current, agent_id: reserved_agent_id, status: :active,
                        phase: :target_pending, reserved: true, result: nil, error: nil}.freeze
              end
              raise
            end
            anchor ||= execution.metadata.dig("coordination", "main_agent_id")
            unless anchor && execution.metadata.dig("coordination", "main_agent_id") == anchor
              raise Phronomy::Storage::ConflictError, "Execution does not belong to this Handoff anchor"
            end
            return @repositories.execution_result(current) unless execution.status == :handed_off
            reserved_agent_id = execution.metadata.fetch("handoff_target_agent_id")
            current = execution.metadata.fetch("handoff_target_execution_id")
          end
        end

        def list_executions(agent_id, after: nil, limit: 100)
          @repositories.executions.list(agent_id, after: after, limit: limit)
        end
      end
    end
  end
end
