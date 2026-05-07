# frozen_string_literal: true

module Phronomy
  module Context
    # Assembles ordered context sections (system prompt, knowledge, conversation
    # history) within a given token budget.
    #
    # Usage:
    #   builder = Phronomy::Context::Builder.new(budget: budget)
    #   builder.add_system(instructions_text)
    #   builder.add_knowledge(knowledge_text)
    #   builder.add_messages(messages)
    #   messages_to_send = builder.build
    #
    # Sections are added in priority order. When the budget is exceeded the
    # lower-priority tail of each section is truncated.
    class Builder
      # @param budget [Phronomy::Context::TokenBudget]
      def initialize(budget:)
        @budget   = budget
        @system   = nil
        @knowledge = []
        @messages = []
      end

      # Set the system instructions text (highest priority).
      # @param text [String]
      def add_system(text)
        @system = text.to_s
        self
      end

      # Append knowledge/RAG text (medium priority).
      # @param text [String]
      def add_knowledge(text)
        @knowledge << text.to_s
        self
      end

      # Set conversation messages (lowest priority — oldest are dropped first).
      # @param messages [Array] list of message-like objects with #role and #content
      def add_messages(messages)
        @messages = Array(messages)
        self
      end

      # Assemble the context respecting the token budget.
      #
      # Returns a hash with:
      #   :system   [String, nil] system prompt (instructions + knowledge)
      #   :messages [Array]       conversation messages that fit within the budget
      #
      # @return [Hash]
      def build
        used = 0

        # System prompt is always included (budget enforcement is informational only).
        system_text = [@system, *@knowledge].compact.join("\n\n")
        used += TokenEstimator.estimate(system_text)

        # Conversation messages — keep as many recent messages as fit.
        remaining = @budget.available(used: used)
        kept = fit_messages_to_budget(@messages, remaining)

        {
          system:   system_text.empty? ? nil : system_text,
          messages: kept
        }
      end

      private

      # Greedily accumulate messages from newest to oldest, stop when budget runs out.
      def fit_messages_to_budget(messages, token_limit)
        return messages if token_limit <= 0 && messages.empty?

        accumulated = 0
        result      = []

        messages.reverse_each do |msg|
          tokens = TokenEstimator.estimate(msg.content.to_s)
          break if accumulated + tokens > token_limit

          accumulated += tokens
          result.unshift(msg)
        end

        result
      end
    end
  end
end
