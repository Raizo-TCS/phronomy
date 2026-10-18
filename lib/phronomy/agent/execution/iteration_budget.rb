# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent policy over existing execution facts. No Engine steps, provider
    # retries, Tool events or context-selected messages contribute to this count.
    # @api private
    module IterationBudget
      LIMIT_KEY = "agent_max_iterations"

      module_function

      def validate_limit(value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError, "Agent max_iterations must be a non-negative Integer"
        end
        value
      end

      def limit_for(execution, default:)
        validate_limit(execution.metadata.fetch(LIMIT_KEY) { default })
      end

      def check!(execution, default:)
        limit = limit_for(execution, default: default)
        completed = execution.llm_calls.length
        if completed >= limit
          raise Phronomy::RecursionLimitError,
            "Agent max_iterations (#{limit}) exceeded after #{completed} LLM calls"
        end
        limit
      end
    end
  end
end
