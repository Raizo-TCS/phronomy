# frozen_string_literal: true

module Phronomy
  module Agent
    ContextPlan = Data.define(
      :selected_unit_ids,
      :derived_contents,
      :selected_tool_ids,
      :ordering_hints,
      :policy_descriptor,
      :metadata
    ) do
      def initialize(**values)
        super(**values.merge(
          selected_unit_ids: Array(values[:selected_unit_ids]).map(&:to_s).freeze,
          derived_contents: Array(values[:derived_contents]).freeze,
          selected_tool_ids: Array(values[:selected_tool_ids]).map(&:to_s).freeze,
          ordering_hints: Immutable.copy(values[:ordering_hints] || {}),
          metadata: Immutable.copy(values[:metadata] || {})
        ))
        freeze
      end
    end
  end
end
