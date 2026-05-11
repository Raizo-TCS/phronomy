# frozen_string_literal: true

module Phronomy
  module VectorStore
    # Pure-Ruby in-memory vector store using cosine similarity.
    #
    # Intended for tests, short-lived agents, and Retrieval::Semantic scenarios where
    # the message count is small enough that a linear scan is fast enough.
    #
    # @example
    #   store = Phronomy::VectorStore::InMemory.new
    #   store.add(id: "1", embedding: [0.1, 0.9], metadata: { message: msg })
    #   results = store.search(query_embedding: [0.1, 0.8], k: 3)
    class InMemory < Base
      def initialize
        @documents = {}
        @mutex = Mutex.new
      end

      # @param id        [String]
      # @param embedding [Array<Float>]
      # @param metadata  [Hash]
      def add(id:, embedding:, metadata: {})
        @mutex.synchronize { @documents[id] = {embedding: embedding, metadata: metadata} }
        self
      end

      # @param query_embedding [Array<Float>]
      # @param k               [Integer]
      # @return [Array<Hash>] sorted by descending score
      def search(query_embedding:, k: 5)
        snapshot = @mutex.synchronize { @documents.dup }
        results = snapshot.map do |id, doc|
          score = cosine_similarity(query_embedding, doc[:embedding])
          {id: id, score: score, metadata: doc[:metadata]}
        end
        results.sort_by { |r| -r[:score] }.first(k)
      end

      def remove(id:)
        @mutex.synchronize { @documents.delete(id) }
        self
      end

      def clear
        @mutex.synchronize { @documents.clear }
        self
      end

      # @return [Integer] number of documents stored
      def size
        @mutex.synchronize { @documents.size }
      end

      private

      def cosine_similarity(a, b)
        return 0.0 if a.empty? || b.empty?

        dot = a.zip(b).sum { |x, y| x * y }
        norm_a = Math.sqrt(a.sum { |x| x**2 })
        norm_b = Math.sqrt(b.sum { |x| x**2 })

        return 0.0 if norm_a.zero? || norm_b.zero?

        dot / (norm_a * norm_b)
      end
    end
  end
end
