# frozen_string_literal: true

module Phronomy
  module Agent
    module Selection
      Unit = Data.define(
        :unit_id,
        :candidate_ids,
        :dependency_unit_ids,
        :kind,
        :constraint,
        :priority,
        :sequence_range,
        :metadata
      ) do
        def initialize(**values)
          effective_constraint = values[:constraint] ||
            Constraint.selectable(origin: :context_policy)
          unless effective_constraint.is_a?(Constraint)
            raise ArgumentError,
              "Selection::Unit constraint must be Selection::Constraint"
          end

          normalized = values.merge(
            unit_id: values.fetch(:unit_id).to_s.freeze,
            candidate_ids: Array(values[:candidate_ids]).map(&:to_s).freeze,
            dependency_unit_ids: Array(values[:dependency_unit_ids]).map(&:to_s).freeze,
            kind: values.fetch(:kind).to_sym,
            constraint: effective_constraint,
            priority: Integer(values[:priority] || 0),
            sequence_range: Array(values[:sequence_range]).map { |v| Integer(v) }.freeze,
            metadata: Immutable.copy(values[:metadata] || {})
          )
          unless normalized[:sequence_range].length == 2
            raise ArgumentError, "Selection::Unit sequence_range must contain two integers"
          end

          super(**normalized)
          freeze
        end

        def with_constraint(constraint)
          self.class.new(
            unit_id: unit_id,
            candidate_ids: candidate_ids,
            dependency_unit_ids: dependency_unit_ids,
            kind: kind,
            constraint: constraint,
            priority: priority,
            sequence_range: sequence_range,
            metadata: metadata
          )
        end
      end
    end
  end
end
