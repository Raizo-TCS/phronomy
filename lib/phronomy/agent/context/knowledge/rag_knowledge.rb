# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Knowledge
        # A KnowledgeSource that retrieves semantically relevant chunks from a VectorStore.
        #
        # On each #fetch call, the query is embedded and the k nearest documents are
        # returned as knowledge chunks.
        #
        # @example
        #   store = Phronomy::RAG::VectorStore::InMemory.new
        #   embeddings = Phronomy::RAG::Embeddings::RubyLLMEmbeddings.new(model: "text-embedding-3-small")
        #   ks = Phronomy::Agent::Context::Knowledge::RAGKnowledge.new(
        #     store: store,
        #     embeddings: embeddings,
        #     k: 5
        #   )
        class RAGKnowledge < Base
          # @param store      [Phronomy::RAG::VectorStore::Base]    vector store holding documents
          # @param embeddings [Phronomy::RAG::Embeddings::Base]     embeddings adapter
          # @param k          [Integer]                        number of chunks to retrieve
          # @param type       [Symbol]                         semantic tag (default :rag)
          # @param source     [String, nil]                    default source label; falls back to
          #   each document's :source metadata when nil
          # @api public
          def initialize(store:, embeddings:, k: 5, type: :rag, source: nil)
            @store = store
            @embeddings = embeddings
            @k = k
            @type = type
            @source = source
          end

          # Embed the query and retrieve the k nearest chunks from the vector store.
          #
          # Returns an empty array when query is nil or blank.
          #
          # @param query              [String, nil]
          # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
          # @return [Array<Hash>]
          # @api public
          def fetch(query: nil, cancellation_token: nil)
            cancellation_token&.raise_if_cancelled!
            return [] if query.nil? || query.strip.empty?

            vector = @embeddings.embed(query, cancellation_token)
            results = @store.search(query_embedding: vector, k: @k, cancellation_token: cancellation_token)
            results.map do |doc|
              chunk = {content: doc[:metadata][:content], type: @type}
              src = @source || doc[:metadata][:source]
              chunk[:source] = src if src
              chunk
            end
          end
        end
      end
    end
  end
end
