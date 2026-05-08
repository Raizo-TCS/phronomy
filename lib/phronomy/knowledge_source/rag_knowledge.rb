# frozen_string_literal: true

module Phronomy
  module KnowledgeSource
    # A KnowledgeSource that retrieves semantically relevant chunks from a VectorStore.
    #
    # On each #fetch call, the query is embedded and the k nearest documents are
    # returned as knowledge chunks.
    #
    # @example
    #   store = Phronomy::VectorStore::InMemory.new
    #   embeddings = Phronomy::Embeddings::RubyLLMEmbeddings.new(model: "text-embedding-3-small")
    #   ks = Phronomy::KnowledgeSource::RAGKnowledge.new(
    #     store: store,
    #     embeddings: embeddings,
    #     k: 5
    #   )
    class RAGKnowledge < Base
      # @param store      [Phronomy::VectorStore::Base]    vector store holding documents
      # @param embeddings [Phronomy::Embeddings::Base]     embeddings adapter
      # @param k          [Integer]                        number of chunks to retrieve
      # @param type       [Symbol]                         semantic tag (default :rag)
      def initialize(store:, embeddings:, k: 5, type: :rag)
        @store = store
        @embeddings = embeddings
        @k = k
        @type = type
      end

      # Embed the query and retrieve the k nearest chunks from the vector store.
      #
      # Returns an empty array when query is nil or blank.
      #
      # @param query [String, nil]
      # @return [Array<Hash>]
      def fetch(query: nil)
        return [] if query.nil? || query.strip.empty?

        vector = @embeddings.embed(query)
        results = @store.search(vector, k: @k)
        results.map { |doc| {content: doc.content, type: @type} }
      end
    end
  end
end
