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
              requirement = unit.requirement
              if unit.unit_id == latest_tool_unit&.unit_id
                requirement = :protocol_required
              elsif requirement == :optional && unit.candidate_ids.any? do |candidate_id|
                candidate = candidates.fetch(candidate_id)
                declared[candidate.candidate_id] || declared[candidate.record_id.to_s]
              end
                requirement = :declared_required
              end

              next unit if requirement == unit.requirement

              ContextSelectionUnit.new(
                unit_id: unit.unit_id,
                candidate_ids: unit.candidate_ids,
                dependency_unit_ids: unit.dependency_unit_ids,
                kind: unit.kind,
                requirement: requirement,
                priority: unit.priority,
                sequence_range: unit.sequence_range,
                metadata: unit.metadata
              )
            end.freeze
          end

          private

          def latest_current_tool_unit(request, units, candidates)
            return unless request.call_mode == :complete

            Array(units).select do |unit|
              unit.kind == :tool_exchange && unit.candidate_ids.any? do |candidate_id|
                candidate = candidates.fetch(candidate_id)
                candidate.source_kind == :working &&
                  candidate.execution_id.to_s == request.execution_id.to_s
              end
            end.max_by { |unit| unit.sequence_range.last }
          end
        end
      end
    end
  end
end
