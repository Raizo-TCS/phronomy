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
        # @param max_index_size [Integer, nil] maximum number of entries kept in the
        #   local index. When nil, the index grows unboundedly. When exceeded, the
        #   oldest entries (by insertion order) are evicted.
        def initialize(embeddings:, store: nil, k: 10, max_index_size: nil)
          @store = store || Phronomy::VectorStore::InMemory.new
          @embeddings = embeddings
          @k = k
          @index = {}   # id => message  (insertion-ordered via Ruby Hash)
          @counter = 0
          @max_index_size = max_index_size
          @mutex = Mutex.new
        end

        # Index a new batch of messages so they are searchable on future #select calls.
        # Called by ConversationManager#save.
        #
        # @param thread_id [String]
        # @param messages  [Array]
        def index(thread_id:, messages:)
          messages.each do |msg|
            embedding = @embeddings.embed(msg.content.to_s)
            @mutex.synchronize do
              id = "#{thread_id}:#{@counter}"
              @counter += 1
              @store.add(id: id, embedding: embedding, metadata: {thread_id: thread_id, message: msg})
              @index[id] = msg
              evict_oldest! if @max_index_size && @index.size > @max_index_size
            end
          end
        end

        # Clear indexed messages for a thread.
        #
        # @param thread_id [String]
        def clear_index(thread_id:)
          @mutex.synchronize do
            ids = @index.keys.select { |id| id.start_with?("#{thread_id}:") }
            ids.each do |id|
              @index.delete(id)
              @store.remove(id: id)
            end
          end
        end

        # Return semantically relevant messages, or recent messages when query is nil.
        #
        # @param messages   [Array]        full history (used as fallback when query is nil)
        # @param query      [String, nil]  current user input for semantic search
        # @param thread_id  [String, nil]  when provided, results are filtered to this thread
        # @return [Array]
        def select(messages, query: nil, thread_id: nil)
          if query && !query.strip.empty?
            query_embedding = @embeddings.embed(query)
            results = @store.search(query_embedding: query_embedding, k: @k * 3)
            results
              .select { |r| thread_id.nil? || r[:metadata][:thread_id] == thread_id }
              .first(@k)
              .map { |r| r[:metadata][:message] }
          else
            messages.last(@k)
          end
        end

        private

        # Evicts the oldest index entry to enforce max_index_size.
        # Must be called inside @mutex.synchronize.
        def evict_oldest!
          oldest_id = @index.keys.first
          return unless oldest_id

          @index.delete(oldest_id)
          @store.remove(id: oldest_id)
        end
      end
    end
  end
end
