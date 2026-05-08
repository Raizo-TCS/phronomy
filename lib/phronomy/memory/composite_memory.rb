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

      # Loads messages from all sources, merging and deduplicating results.
      #
      # @param thread_id [String]
      # @param query     [String, nil]
      # @return [Array]
      def load_messages(thread_id:, query: nil, **)
        all_messages = []
        seen_contents = {}

        @sources.each do |source|
          msgs = source[:memory].load_messages(thread_id: thread_id, query: query)

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
    end
  end
end
