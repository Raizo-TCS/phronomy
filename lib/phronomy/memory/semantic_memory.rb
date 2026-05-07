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
      # @param embedding_model [String, nil] model to use for RubyLLM.embed
      # @param k               [Integer]     number of results to return
      def initialize(store: nil, embedding_model: nil, k: 10)
        @store = store || Phronomy::VectorStore::InMemory.new
        @embedding_model = embedding_model
        @k = k
        @messages = {}  # id => message
        @counter = 0
      end

      # Retrieve relevant messages.
      #
      # When query is provided the k semantically closest messages are returned.
      # When token_budget is provided the result is additionally trimmed to fit.
      # When no query is provided, falls back to the k most recent messages.
      #
      # @param thread_id    [String]
      # @param query        [String, nil]
      # @param token_budget [Phronomy::Context::TokenBudget, nil]
      # @return [Array]
      def load_messages(thread_id:, query: nil, token_budget: nil, **)
        if query
          semantic_search(thread_id, query, token_budget)
        else
          recent_messages(thread_id, token_budget)
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
        opts = @embedding_model ? {model: @embedding_model} : {}
        RubyLLM.embed(text, **opts).vectors
      end

      def semantic_search(thread_id, query, token_budget)
        query_embedding = embed(query)
        results = @store.search(query_embedding: query_embedding, k: @k * 3)
        messages = results
          .select { |r| r[:metadata][:thread_id] == thread_id }
          .first(@k)
          .map { |r| r[:metadata][:message] }

        token_budget ? fit_to_budget(messages, token_budget.effective_input_limit) : messages
      end

      def recent_messages(thread_id, token_budget)
        msgs = @messages
          .select { |id, _| id.start_with?("#{thread_id}:") }
          .sort_by { |id, _| id }
          .map { |_, msg| msg }
          .last(@k)
        token_budget ? fit_to_budget(msgs, token_budget.effective_input_limit) : msgs
      end

      def fit_to_budget(messages, token_limit)
        accumulated = 0
        result = []
        messages.reverse_each do |msg|
          tokens = Phronomy::Context::TokenEstimator.estimate(msg.content.to_s)
          break if accumulated + tokens > token_limit

          accumulated += tokens
          result.unshift(msg)
        end
        result
      end
    end
  end
end
