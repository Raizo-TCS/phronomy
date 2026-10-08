# frozen_string_literal: true

require_relative "invalid_result_error"

module Phronomy
  module VectorStore
    # Owns synchronous operations, input validation and the public result shape.
    # Backends implement protected perform_* operations and embedding_dimension.
    # No execution client, SDK or embedding provider is selected by this class.
    # @api public
    class Base
      # Validate before invoking the backend. Cancellation is checked before the
      # write, never reported after a successful write. No operation is retried.
      # @param id [String]
      # @param embedding [Array<Numeric>]
      # @param metadata [Hash]
      # @param cancellation_token [#raise_if_cancelled!, nil]
      # @return [self]
      # @api public
      def add(id:, embedding:, metadata: {}, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        validate_id!(id)
        raise ArgumentError, "metadata must be a Hash" unless metadata.is_a?(Hash)
        vector = validate_vector!(embedding)
        perform_add(id: id, embedding: vector, metadata: metadata, cancellation_token: cancellation_token)
        self
      end

      # Return at most k results ordered by descending similarity. Malformed
      # backend output raises InvalidResultError; transport errors propagate.
      # @param query_embedding [Array<Numeric>]
      # @param k [Integer, String] positive integer or its decimal string
      # @param cancellation_token [#raise_if_cancelled!, nil]
      # @return [Array<Hash>]
      # @api public
      def search(query_embedding:, k: 5, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        limit = validate_k!(k)
        vector = validate_vector!(query_embedding)
        results = perform_search(query_embedding: vector, k: limit, cancellation_token: cancellation_token)
        validate_results!(results, limit)
        results
      end

      # Remove a document; an absent id is a successful no-op.
      # @param id [String]
      # @return [self]
      # @api public
      def remove(id:)
        validate_id!(id)
        perform_remove(id: id)
        self
      end

      # Clear documents without changing the configured dimension.
      # @return [self]
      # @api public
      def clear
        perform_clear
        self
      end

      # @return [Integer] non-negative document count
      # @api public
      def size
        count = perform_size
        unless count.is_a?(Integer) && count >= 0
          raise InvalidResultError, "size must return a non-negative Integer"
        end
        count
      end

      protected

      # @return [Integer, nil] nil delegates dimension enforcement to the backend
      # @api public
      def embedding_dimension
        nil
      end

      # Storage extension point; inputs have passed common validation.
      # @api public
      def perform_add(id:, embedding:, metadata:, cancellation_token:)
        raise NotImplementedError, "#{self.class}#perform_add is not implemented"
      end

      # Search extension point; return the documented result hashes in order.
      # @api public
      def perform_search(query_embedding:, k:, cancellation_token:)
        raise NotImplementedError, "#{self.class}#perform_search is not implemented"
      end

      # @api public
      def perform_remove(id:)
        raise NotImplementedError, "#{self.class}#perform_remove is not implemented"
      end

      # @api public
      def perform_clear
        raise NotImplementedError, "#{self.class}#perform_clear is not implemented"
      end

      # @api public
      def perform_size
        raise NotImplementedError, "#{self.class}#perform_size is not implemented"
      end

      private

      def validate_id!(id)
        raise ArgumentError, "id must be a String" unless id.is_a?(String)
      end

      def finite_real?(value)
        value.is_a?(Numeric) && value.real? && value.finite? && value.to_f.finite?
      end

      def validate_vector!(embedding)
        unless embedding.is_a?(Array) && embedding.all? { |value| finite_real?(value) }
          raise ArgumentError, "embedding must be an Array of finite real numbers"
        end
        dimension = embedding_dimension
        if dimension && embedding.size != dimension
          raise ArgumentError, "Embedding dimension mismatch: expected #{dimension}, got #{embedding.size}"
        end
        embedding.map(&:to_f)
      end

      def validate_k!(k)
        valid = k.is_a?(Integer) || (k.is_a?(String) && k.match?(/\A\+?\d+\z/))
        unless valid
          raise ArgumentError, "k must be a positive integer"
        end
        value = k.is_a?(String) ? Integer(k, 10) : k
        raise ArgumentError, "k must be a positive integer" unless value >= 1
        value
      end

      def validate_results!(results, limit)
        unless results.is_a?(Array) && results.size <= limit
          raise InvalidResultError, "search must return an Array with at most k results"
        end
        previous = Float::INFINITY
        results.each do |result|
          unless result.is_a?(Hash) && result[:id].is_a?(String) &&
              result[:metadata].is_a?(Hash) && finite_real?(result[:score])
            raise InvalidResultError, "search results require a String id, finite score and Hash metadata"
          end
          if result[:score] > previous
            raise InvalidResultError, "search results must be ordered by descending score"
          end
          previous = result[:score]
        end
      end
    end
  end
end
