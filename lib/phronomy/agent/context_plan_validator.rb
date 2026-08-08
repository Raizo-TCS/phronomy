# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextPlanValidator
      ValidatedContextPlan = Data.define(
        :plan, :units, :selected_units, :selected_candidates
      ) do
        def initialize(**values)
          super(**values.merge(
            units: Array(values[:units]).freeze,
            selected_units: Array(values[:selected_units]).freeze,
            selected_candidates: Array(values[:selected_candidates]).freeze
          ))
          freeze
        end
      end

      def validate!(request:, plan:)
        unless plan.is_a?(ContextPlan)
          raise ArgumentError, "Context Policy returned #{plan.class}, expected #{ContextPlan}"
        end

        units = request.parts.fetch(:unit_builder).build(request.candidates)
        units = request.parts.fetch(:required_context_resolver).resolve(
          request: request,
          units: units
        )
        unit_index = units.to_h { |unit| [unit.unit_id, unit] }
        unknown = plan.selected_unit_ids.reject { |unit_id| unit_index.key?(unit_id) }
        raise ArgumentError, "ContextPlan contains unknown units: #{unknown.inspect}" unless unknown.empty?

        selected_units = plan.selected_unit_ids.map { |unit_id| unit_index.fetch(unit_id) }
        required = units.reject { |unit| unit.requirement == :optional }.map(&:unit_id)
        missing_required = required - plan.selected_unit_ids
        unless missing_required.empty?
          raise Phronomy::ContextBudgetExceededError,
            "ContextPlan omitted required units: #{missing_required.inspect}"
        end

        candidate_index = request.candidates.to_h { |candidate| [candidate.candidate_id, candidate] }
        selected_candidates = selected_units.flat_map(&:candidate_ids).uniq.map do |candidate_id|
          candidate_index.fetch(candidate_id)
        end
        validate_tool_dependencies!(request.candidates, selected_candidates)
        validate_derived_contents!(request, plan)

        ValidatedContextPlan.new(
          plan: plan,
          units: units,
          selected_units: selected_units,
          selected_candidates: selected_candidates
        )
      end

      private

      def validate_tool_dependencies!(all_candidates, selected_candidates)
        all_calls = Array(all_candidates).select { |candidate| candidate.category == :tool_call }
          .to_h { |candidate| [candidate.tool_call_id, candidate] }
        all_results = Array(all_candidates).select { |candidate| candidate.category == :tool_result }
          .group_by(&:tool_call_id)
        selected_ids = selected_candidates.to_h { |candidate| [candidate.candidate_id, true] }

        selected_candidates.each do |candidate|
          case candidate.category
          when :tool_result
            call = all_calls[candidate.tool_call_id]
            unless call && selected_ids[call.candidate_id]
              raise ArgumentError,
                "ContextPlan selected orphan Tool Result: #{candidate.tool_call_id}"
            end
          when :tool_call
            results = all_results.fetch(candidate.tool_call_id, [])
            if results.empty?
              raise ArgumentError,
                "ContextPlan selected Tool Call without a Tool Result: #{candidate.tool_call_id}"
            end
            missing = results.reject { |result| selected_ids[result.candidate_id] }
            unless missing.empty?
              raise ArgumentError,
                "ContextPlan split Tool Call/Result dependency: #{candidate.tool_call_id}"
            end
          end
        end
      end

      def validate_derived_contents!(request, plan)
        known = request.candidates.to_h { |candidate| [candidate.candidate_id, true] }
        plan.derived_contents.each do |derived|
          unless derived.is_a?(DerivedContentSpec)
            raise ArgumentError,
              "ContextPlan derived content must be DerivedContentSpec, got #{derived.class}"
          end
          unknown = derived.coverage_candidate_ids.reject { |id| known[id] }
          raise ArgumentError, "Derived content covers unknown candidates: #{unknown.inspect}" unless unknown.empty?
        end
      end
    end
  end
end
