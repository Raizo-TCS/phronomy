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
      # @param dimension [Integer, nil] expected embedding dimension.
      #   When nil, the dimension is inferred from the first call to #add.
      #   For multi-threaded use, pass dimension: explicitly; concurrent first
      #   adds are not guaranteed to be race-free.
      def initialize(dimension: nil)
        @documents = {}
        @expected_dimension = dimension
      end

      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::CancellationToken, nil]
      def add(id:, embedding:, metadata: {}, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        # Establish expected dimension on first add, then validate.
        @expected_dimension ||= embedding.size
        validate_embedding_dimension!(embedding, @expected_dimension)
        @documents[id] = {embedding: embedding, metadata: metadata}
        self
      end

      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]
      # @param cancellation_token [Phronomy::CancellationToken, nil]
      # @return [Array<Hash>] sorted by descending score
      def search(query_embedding:, k: 5, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        k = validate_k!(k)
        # search never establishes dimension; validate only when dimension is known.
        validate_embedding_dimension!(query_embedding, @expected_dimension)
        # Take an atomic snapshot before iterating.  Hash#dup is a C-level
        # call that completes without releasing the GVL, so it is atomic with
        # respect to any other Ruby thread.  Iterating the copy instead of
        # @documents directly prevents "can't add a new key into hash during
        # iteration" when a concurrent thread calls #add.
        snapshot = @documents.dup
        results = snapshot.map do |id, doc|
          score = cosine_similarity(query_embedding, doc[:embedding])
          {id: id, score: score, metadata: doc[:metadata]}
        end
        results.sort_by { |r| -r[:score] }.first(k)
      end

      def remove(id:)
        @documents.delete(id)
        self
      end

      def clear
        @documents.clear
        self
      end

      # @return [Integer] number of documents stored
      def size
        @documents.size
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
