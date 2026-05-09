# frozen_string_literal: true

module Phronomy
  module Memory
    module Retrieval
      # Retrieval strategy that returns the k semantically closest messages to the query.
      #
      # Messages are indexed in a VectorStore on save. On retrieval, the query is
      # embedded and the k nearest messages are returned. Falls back to the k most
      # recent messages when no query is provided.
      #
      # @example
      #   retrieval = Phronomy::Memory::Retrieval::Semantic.new(
      #     embeddings: Phronomy::Embeddings::RubyLLMEmbeddings.new(model: "text-embedding-3-small"),
      #     k: 10
      #   )
      class Semantic < Base
        # @param store      [Phronomy::VectorStore::Base]  vector store (default InMemory)
        # @param embeddings [Phronomy::Embeddings::Base]   embeddings adapter
        # @param k          [Integer]                      number of messages to retrieve
        def initialize(embeddings:, store: nil, k: 10)
          @store = store || Phronomy::VectorStore::InMemory.new
          @embeddings = embeddings
          @k = k
          @index = {}   # id => message
          @counter = 0
        end

        # Index a new batch of messages so they are searchable on future #select calls.
        # Called by ConversationManager#save.
        #
        # @param thread_id [String]
        # @param messages  [Array]
        def index(thread_id:, messages:)
          messages.each do |msg|
            id = "#{thread_id}:#{@counter}"
            @counter += 1
            embedding = @embeddings.embed(msg.content.to_s)
            @store.add(id: id, embedding: embedding, metadata: {thread_id: thread_id, message: msg})
            @index[id] = msg
          end
        end

        # Clear indexed messages for a thread.
        #
        # @param thread_id [String]
        def clear_index(thread_id:)
          ids = @index.select { |id, _| id.start_with?("#{thread_id}:") }.keys
          ids.each do |id|
            @index.delete(id)
            @store.remove(id: id)
          end
        end

        # Return semantically relevant messages, or recent messages when query is nil.
        #
        # @param messages [Array]       full history (used as fallback when query is nil)
        # @param query    [String, nil] current user input for semantic search
        # @return [Array]
        def select(messages, query: nil)
          if query && !query.strip.empty?
            query_embedding = @embeddings.embed(query)
            results = @store.search(query_embedding: query_embedding, k: @k * 3)
            results
              .select { |r| r[:metadata][:thread_id] == extract_thread_from_results(r, messages) }
              .first(@k)
              .map { |r| r[:metadata][:message] }
          else
            messages.last(@k)
          end
        end

        private

        def extract_thread_from_results(result, _messages)
          result[:metadata][:thread_id]
        end
      end
    end
  end
end
