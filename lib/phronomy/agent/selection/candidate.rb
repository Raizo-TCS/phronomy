# frozen_string_literal: true

module Phronomy
  module Agent
    module Selection
      Candidate = Data.define(
        :candidate_id,
        :source_kind,
        :category,
        :role,
        :content_ref,
        :record_id,
        :agent_id,
        :execution_id,
        :llm_call_id,
        :tool_call_id,
        :sequence,
        :constraint,
        :priority,
        :metadata
      ) do
        def initialize(**values)
          effective_constraint = values[:constraint] ||
            Constraint.selectable(origin: :context_policy)
          unless effective_constraint.is_a?(Constraint)
            raise ArgumentError,
              "Selection::Candidate constraint must be Selection::Constraint"
          end

          normalized = values.merge(
            candidate_id: values.fetch(:candidate_id).to_s.freeze,
            source_kind: values.fetch(:source_kind).to_sym,
            category: values.fetch(:category).to_sym,
            role: values[:role]&.to_sym,
            content_ref: values.fetch(:content_ref).to_s.freeze,
            record_id: values[:record_id]&.to_s&.freeze,
            agent_id: values[:agent_id]&.to_s&.freeze,
            execution_id: values[:execution_id]&.to_s&.freeze,
            llm_call_id: values[:llm_call_id]&.to_s&.freeze,
            tool_call_id: values[:tool_call_id]&.to_s&.freeze,
            sequence: values[:sequence] && Integer(values[:sequence]),
            constraint: effective_constraint,
            priority: Integer(values[:priority] || 0),
            metadata: Immutable.copy(values[:metadata] || {})
          )

          super(**normalized)
          freeze
        end
      end
    end
  end
end
