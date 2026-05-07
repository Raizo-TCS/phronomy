# frozen_string_literal: true

module Phronomy
  module Memory
    # Merges results from multiple memory sources within a single token budget.
    #
    # Useful for combining a semantic (long-term) memory with a recent-turns
    # (short-term) memory while keeping total token usage under control.
    #
    # @example
    #   composite = Phronomy::Memory::CompositeMemory.new(
    #     sources: [
    #       { memory: semantic_memory, weight: 0.6 },
    #       { memory: window_memory,   weight: 0.4 }
    #     ]
    #   )
    #
    # Each source may specify a :weight (0.0 – 1.0) that controls what fraction
    # of the total token budget is allocated to it.  Weights are normalised so
    # they do not need to sum to 1.
    class CompositeMemory < Base
      # @param sources [Array<Hash>] each entry: { memory:, weight: } (weight default 1.0)
      def initialize(sources:)
        @sources = sources.map { |s| {memory: s[:memory], weight: (s[:weight] || 1.0).to_f} }
      end

      # Loads messages from all sources, allocating tokens proportionally.
      # Deduplication is performed by object identity (later sources lose if same object appears).
      #
      # @param thread_id    [String]
      # @param token_budget [Phronomy::Context::TokenBudget, nil]
      # @param query        [String, nil]
      # @return [Array]
      def load_messages(thread_id:, token_budget: nil, query: nil, **)
        total_weight = @sources.sum { |s| s[:weight] }

        all_messages = []
        seen_contents = {}

        @sources.each do |source|
          sub_budget = if token_budget
            fraction = source[:weight] / total_weight
            allocated = (token_budget.effective_input_limit * fraction).to_i
            build_sub_budget(token_budget, allocated)
          end

          msgs = source[:memory].load_messages(
            thread_id: thread_id,
            token_budget: sub_budget,
            query: query
          )

          msgs.each do |msg|
            key = "#{msg.role}:#{msg.content}"
            next if seen_contents[key]

            seen_contents[key] = true
            all_messages << msg
          end
        end

        # Final sort — system messages first, others preserve insertion order.
        systems = all_messages.select { |m| m.role.to_sym == :system }
        others = all_messages.reject { |m| m.role.to_sym == :system }
        systems + others
      end

      def save_messages(thread_id:, messages:)
        # Delegate save to all sources.
        @sources.each { |s| s[:memory].save_messages(thread_id: thread_id, messages: messages) }
      end

      def clear(thread_id:)
        @sources.each { |s| s[:memory].clear(thread_id: thread_id) }
      end

      private

      def build_sub_budget(parent_budget, allocated_tokens)
        Phronomy::Context::TokenBudget.new(
          context_window: parent_budget.context_window,
          max_output_tokens: parent_budget.max_output_tokens,
          overhead: parent_budget.context_window - parent_budget.max_output_tokens - allocated_tokens
        )
      end
    end
  end
end
