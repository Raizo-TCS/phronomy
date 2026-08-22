# frozen_string_literal: true

module Phronomy
  module Agent
    module ContextParts
      module Budget
        class TokenBudgetPacker
          def pack(request:, units:)
            selectable_units = Array(units).reject { |unit| unit.constraint.forbidden? }
            return selectable_units.freeze unless request.token_budget

            candidate_index = request.candidates.to_h { |candidate| [candidate.candidate_id, candidate] }
            mandatory = Integer(request.metadata["mandatory_token_estimate"] || 0)
            limit = request.token_budget.effective_input_limit
            if mandatory > limit
              raise Phronomy::ContextBudgetExceededError,
                "Mandatory content (estimated #{mandatory} tokens) exceeds " \
                "available input budget (#{limit} tokens)"
            end

            remaining = limit - mandatory
            required, optional = selectable_units.partition { |unit| unit.constraint.required? }
            required_cost = required.sum { |unit| unit_cost(unit, candidate_index) }
            if required_cost > remaining
              raise Phronomy::ContextBudgetExceededError,
                "Required Context (estimated #{required_cost} tokens) exceeds " \
                "remaining input budget (#{remaining} tokens after mandatory content)"
            end

            selected = required.dup
            remaining -= required_cost
            optional.each do |unit|
              cost = unit_cost(unit, candidate_index)
              next if cost > remaining

              selected << unit
              remaining -= cost
            end
            selected.freeze
          end

          private

          def unit_cost(unit, candidate_index)
            unit.candidate_ids.sum do |candidate_id|
              candidate = candidate_index.fetch(candidate_id)
              Integer(candidate.metadata["estimated_tokens"] || 0)
            end
          end
        end
      end
    end
  end
end
