# frozen_string_literal: true

module Phronomy
  module Agent
    ContextPlan = Data.define(
      :instruction,
      :knowledge,
      :tools,
      :conversation,
      :metadata
    ) do
      def initialize(
        instruction: [],
        knowledge: [],
        tools: [],
        conversation: [],
        metadata: {}
      )
        super(
          instruction: Array(instruction).freeze,
          knowledge: Array(knowledge).freeze,
          tools: Array(tools).freeze,
          conversation: Array(conversation).map { |group| Array(group).freeze }.freeze,
          metadata: Immutable.copy(metadata || {})
        )
        freeze
      end
    end
  end
end
