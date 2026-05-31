# frozen_string_literal: true

module Phronomy
  module VectorStore
    # Abstract interface for vector stores.
    #
    # Implementations manage a collection of (embedding, metadata) pairs and
    # support similarity search.
    #
    # Async methods (`search_async`, `add_async`, `remove_async`, `clear_async`)
    # are provided by the {AsyncBackend} mixin which defaults to routing calls
    # through {BlockingAdapterPool}.  Backends with native async drivers may
    # override individual async methods without touching the pool at all.
    class Base
      include AsyncBackend

      # Add a document with its vector embedding.
      #
      # @param id                 [String]                         unique document identifier
      # @param embedding          [Array<Float>]                   vector embedding
      # @param metadata           [Hash]                           arbitrary metadata (e.g. the original message object)
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
      # @api public
      def add(id:, embedding:, metadata: {}, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        raise NotImplementedError, "#{self.class}#add is not implemented"
      end

      # Return the k most similar documents to the query embedding.
      #
      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]                        number of results
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
      # @return [Array<Hash>] each element: { id:, score:, metadata: }
      # @api public
      def search(query_embedding:, k: 5, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        raise NotImplementedError, "#{self.class}#search is not implemented"
      end

      # Remove a single document by id.
      #
      # @param id [String] document identifier
      # @api public
      def remove(id:)
        raise NotImplementedError, "#{self.class}#remove is not implemented"
      end

      # Remove all documents.
      def clear
        raise NotImplementedError, "#{self.class}#clear is not implemented"
      end

      # Return the number of documents stored.
      #
      # @return [Integer]
      # @api public
      def size
        raise NotImplementedError, "#{self.class}#size is not implemented"
      end

      private

      # Validates that embedding has the expected dimension.
      # Raises ArgumentError if sizes differ.
      # A nil expected_dimension is a no-op (dimension not yet established).
      def validate_embedding_dimension!(embedding, expected_dimension)
        return unless expected_dimension

        actual = embedding.size
        return if actual == expected_dimension

        raise ArgumentError,
          "Embedding dimension mismatch: expected #{expected_dimension}, got #{actual}"
      end

      # Validates that k is a positive integer.
      # Accepts any value accepted by Integer() (e.g. "5"), but raises
      # ArgumentError for non-integer strings, zero, and negative values.
      def validate_k!(k)
        int_k = Integer(k)
        raise ArgumentError, "k must be a positive integer, got #{int_k}" unless int_k >= 1
        int_k
      rescue ArgumentError => e
        raise ArgumentError, "k must be a positive integer: #{e.message}"
      end
    end
  end
end
