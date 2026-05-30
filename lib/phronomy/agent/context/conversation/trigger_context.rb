# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Conversation
    # Read-only context passed to the +on_compaction_trigger+ callback.
    #
    # The callback inspects the current message list and budget, then returns
    # a truthy value to trigger compaction or a falsy value to skip it.
    #
    # No mutations are allowed through this object; use CompactionContext
    # (passed to +on_compact+) for actual modifications.
    #
    # @example Trigger compaction when messages exceed 80% of the input budget
    #   on_compaction_trigger do |ctx|
    #     limit = ctx.budget&.available(used: 0) || Float::INFINITY
    #     ctx.total_tokens > limit * 0.8
    #   end
    class TriggerContext
      # @return [Array<Hash>] frozen snapshot of message elements
      #   each element: { seq: Integer, message: Object, tokens: Integer, role: Symbol }
      attr_reader :message_elements

      # @return [Phronomy::LlmContextWindow::TokenBudget, nil] token budget for this invocation
      attr_reader :budget

      # @return [Integer] total estimated token count of all message elements
      attr_reader :total_tokens

      # @param message_elements [Array<Hash>]
      # @param budget [Phronomy::LlmContextWindow::TokenBudget, nil]
      # @api private
      def initialize(message_elements:, budget:)
        @message_elements = message_elements.dup.freeze
        @budget = budget
        @total_tokens = message_elements.sum { |e| e[:tokens] }
      end
    end
  end
end
end
end
