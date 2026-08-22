# frozen_string_literal: true

module Phronomy
  module Agent
    module Selection
      module Selectors
        class RecentFirstSelector
          def order(request:, units:)
            candidates = request.candidates.to_h { |candidate| [candidate.candidate_id, candidate] }
            Array(units).reject { |unit| unit.constraint.forbidden? }.sort_by do |unit|
              required_rank = unit.constraint.required? ? 0 : 1
              current_rank = current_execution_unit?(request, unit, candidates) ? 0 : 1
              [required_rank, current_rank, -unit.priority, -unit.sequence_range.last]
            end.freeze
          end

          private

          def current_execution_unit?(request, unit, candidates)
            unit.candidate_ids.any? do |candidate_id|
              candidate = candidates.fetch(candidate_id)
              candidate.execution_id.to_s == request.execution_id.to_s &&
                candidate.source_kind == :working
            end
          end
        end
      end
    end
  end
end
