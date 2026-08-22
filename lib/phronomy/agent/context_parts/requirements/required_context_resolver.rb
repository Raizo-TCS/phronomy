# frozen_string_literal: true

module Phronomy
  module Agent
    module ContextParts
      module Requirements
        class RequiredContextResolver
          def resolve(request:, units:)
            candidates = request.candidates.to_h { |candidate| [candidate.candidate_id, candidate] }
            declared = request.required_coverage.to_h { |value| [value.to_s, true] }
            latest_tool_unit = latest_current_tool_unit(request, units, candidates)

            Array(units).map do |unit|
              constraint = unit.constraint
              if unit.unit_id == latest_tool_unit&.unit_id
                constraint = Selection::Constraint.required(
                  origin: :framework_protocol,
                  reason: "latest current Tool exchange"
                )
              elsif current_request_unit?(request, unit, candidates)
                constraint = Selection::Constraint.required(
                  origin: :framework_protocol,
                  reason: "current user request"
                )
              elsif constraint.selectable? && unit.candidate_ids.any? do |candidate_id|
                candidate = candidates.fetch(candidate_id)
                declared[candidate.candidate_id] || declared[candidate.record_id.to_s]
              end
                constraint = Selection::Constraint.required(
                  origin: :context_policy_declared,
                  reason: "declared required coverage"
                )
              end

              next unit if constraint == unit.constraint
              unit.with_constraint(constraint)
            end.freeze
          end

          private

          def current_request_unit?(request, unit, candidates)
            return false unless request.call_mode == :complete

            unit.candidate_ids.any? do |candidate_id|
              candidate = candidates.fetch(candidate_id)
              candidate.category == :external_message &&
                current_execution_working_candidate?(request, candidate)
            end
          end

          def latest_current_tool_unit(request, units, candidates)
            return unless request.call_mode == :complete

            Array(units).select do |unit|
              unit.kind == :tool_exchange && unit.candidate_ids.any? do |candidate_id|
                candidate = candidates.fetch(candidate_id)
                current_execution_working_candidate?(request, candidate)
              end
            end.max_by { |unit| unit.sequence_range.last }
          end

          def current_execution_working_candidate?(request, candidate)
            candidate.source_kind == :working &&
              candidate.execution_id.to_s == request.execution_id.to_s
          end
        end
      end
    end
  end
end
