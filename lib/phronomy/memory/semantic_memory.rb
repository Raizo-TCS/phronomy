# frozen_string_literal: true

module Phronomy
  module Memory
    # Embedding-based semantic memory.
    #
    # Messages are stored in a VectorStore so that load_messages can retrieve
    # the most semantically relevant messages for a given query, rather than
    # only the most recent ones.
    #
    # When no query is supplied, falls back to returning the most recent k messages.
    #
    # @example Basic usage
    #   memory = Phronomy::Memory::SemanticMemory.new(
    #     embedding_model: "text-embedding-3-small",
    #     k: 10
    #   )
    #
    # @example With explicit vector store
    #   memory = Phronomy::Memory::SemanticMemory.new(
    #     store: Phronomy::VectorStore::InMemory.new,
    #     embedding_model: "text-embedding-3-small"
    #   )
    class SemanticMemory < Base
      # @param store           [Phronomy::VectorStore::Base] vector store; default InMemory
      # @param embeddings       [Phronomy::Embeddings::Base, nil] embeddings adapter; default RubyLLMEmbeddings
      # @param embedding_model  [String, nil] shorthand for RubyLLMEmbeddings model; ignored when embeddings: is given
      # @param k                [Integer]     number of results to return
      def initialize(store: nil, embeddings: nil, embedding_model: nil, k: 10, async: false, queue: :default)
        super(async: async, queue: queue)
        @store = store || Phronomy::VectorStore::InMemory.new
        @embeddings = embeddings || Phronomy::Embeddings::RubyLLMEmbeddings.new(model: embedding_model)
        @k = k
        @messages = {}  # id => message
        @counter = 0
      end

      # Retrieve relevant messages.
      #
      # When query is provided the k semantically closest messages are returned.
      # When no query is provided, falls back to the k most recent messages.
      #
      # @param thread_id [String]
      # @param query     [String, nil]
      # @return [Array]
      def load_messages(thread_id:, query: nil, **)
        if query
          semantic_search(thread_id, query)
        else
          recent_messages(thread_id)
        end
      end

      def save_messages(thread_id:, messages:)
        messages.each do |msg|
          id = "#{thread_id}:#{@counter}"
          @counter += 1
          embedding = embed(msg.content.to_s)
          @store.add(id: id, embedding: embedding, metadata: {thread_id: thread_id, message: msg})
          @messages[id] = msg
        end
      end

      def clear(thread_id:)
        # Remove messages belonging to this thread.
        ids_to_remove = @messages.select { |id, _| id.start_with?("#{thread_id}:") }.keys
        ids_to_remove.each { |id| @messages.delete(id) }
        @store.clear
        # Re-index remaining messages from other threads.
        @messages.each do |id, msg|
          embedding = embed(msg.content.to_s)
          @store.add(id: id, embedding: embedding, metadata: {thread_id: id.split(":").first, message: msg})
        end
      end

      private

      def embed(text)
        @embeddings.embed(text)
      end

      def semantic_search(thread_id, query)
        query_embedding = embed(query)
        results = @store.search(query_embedding: query_embedding, k: @k * 3)
        results
          .select { |r| r[:metadata][:thread_id] == thread_id }
          .first(@k)
          .map { |r| r[:metadata][:message] }
      end

      def recent_messages(thread_id)
        @messages
          .select { |id, _| id.start_with?("#{thread_id}:") }
          .sort_by { |id, _| id }
          .map { |_, msg| msg }
          .last(@k)
      end
    end
  end
end
