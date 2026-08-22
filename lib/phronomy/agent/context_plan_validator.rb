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
        validated = Selection::Validator.new.validate!(
          candidates: request.candidates,
          units: units,
          selected_unit_ids: plan.selected_unit_ids
        )
        validate_derived_contents!(request, plan)

        ValidatedContextPlan.new(
          plan: plan,
          units: validated.units,
          selected_units: validated.selected_units,
          selected_candidates: validated.selected_candidates
        )
      rescue Selection::ValidationError => error
        if error.code == :missing_required
          raise Phronomy::ContextBudgetExceededError,
            "ContextPlan omitted required units: #{error.unit_ids.inspect}"
        end
        raise ArgumentError, error.message
      end

      private

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
