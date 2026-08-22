# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Typed private control request produced from one intercepted Handoff capability.
    # @api private
    HandoffRequest = Data.define(
      :handoff, :responsibility, :selection_intent, :llm_call_id, :tool_call_id
    ) do
      def initialize(handoff:, responsibility:, selection_intent:, llm_call_id: nil, tool_call_id: nil)
        responsibility = responsibility.to_s.strip
        raise ArgumentError, "Handoff responsibility must not be empty" if responsibility.empty?
        unless handoff.is_a?(Handoff)
          raise ArgumentError, "handoff must be a Phronomy::MultiAgent::Handoff"
        end

        normalized = handoff.policy.selectable_categories.to_h do |category|
          raw = selection_intent.fetch(category) do
            handoff.policy.default_include?(category)
          end
          unless raw == true || raw == false
            raise ArgumentError,
              "Handoff selection for #{category.inspect} must be boolean"
          end
          [category, raw]
        end.freeze

        unknown = selection_intent.keys.map(&:to_sym) - handoff.policy.selectable_categories
        unless unknown.empty?
          raise ArgumentError,
            "Handoff selection attempts to override non-selectable categories: #{unknown.inspect}"
        end

        super(
          handoff: handoff,
          responsibility: responsibility.freeze,
          selection_intent: normalized,
          llm_call_id: llm_call_id&.to_s&.freeze,
          tool_call_id: tool_call_id&.to_s&.freeze
        )
        freeze
      end
    end
  end
end
