# frozen_string_literal: true

module Phronomy
  module Memory
    module Retrieval
      # Retrieval strategy that merges results from multiple child retrieval strategies.
      #
      # Each child is given a weight that controls what fraction of a token budget
      # it should consume. Results are deduplicated (by role + content) and
      # system messages are sorted to the front.
      #
      # @example
      #   composite = Phronomy::Memory::Retrieval::Composite.new(
      #     sources: [
      #       { retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 5),    weight: 0.4 },
      #       { retrieval: Phronomy::Memory::Retrieval::Semantic.new(...),   weight: 0.6 }
      #     ]
      #   )
      #   manager = Phronomy::Memory::ConversationManager.new(
      #     storage:   Phronomy::Memory::Storage::InMemory.new,
      #     retrieval: composite
      #   )
      class Composite < Base
        # @param sources [Array<Hash>] each entry: { retrieval:, weight: } (weight default 1.0)
        def initialize(sources:)
          @sources = sources.map { |s| {retrieval: s[:retrieval], weight: (s[:weight] || 1.0).to_f} }
        end

        # Merge results from all child retrievals, deduplicating by role+content.
        # System messages are sorted to the front; others preserve insertion order.
        #
        # @param messages  [Array]        full chronological history
        # @param query     [String, nil]  forwarded to each child retrieval
        # @param thread_id [String, nil]  forwarded to each child retrieval
        # @return [Array]
        def select(messages, query: nil, thread_id: nil)
          all_messages = []
          seen = {}

          @sources.each do |source|
            source[:retrieval].select(messages, query: query, thread_id: thread_id).each do |msg|
              key = "#{msg.role}:#{msg.content}"
              next if seen[key]

              seen[key] = true
              all_messages << msg
            end
          end

          systems = all_messages.select { |m| m.role.to_sym == :system }
          others = all_messages.reject { |m| m.role.to_sym == :system }
          systems + others
        end

        # Forward index calls to all child retrievals that support it.
        #
        # @param thread_id [String]
        # @param messages  [Array]
        def index(thread_id:, messages:)
          @sources.each do |source|
            source[:retrieval].index(thread_id: thread_id, messages: messages) if source[:retrieval].respond_to?(:index)
          end
        end

        # Forward clear_index to all child retrievals that support it.
        #
        # @param thread_id [String]
        def clear_index(thread_id:)
          @sources.each do |source|
            source[:retrieval].clear_index(thread_id: thread_id) if source[:retrieval].respond_to?(:clear_index)
          end
        end
      end
    end
  end
end
