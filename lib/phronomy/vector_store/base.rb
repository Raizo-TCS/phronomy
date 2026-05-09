# frozen_string_literal: true

module Phronomy
  module VectorStore
    # Abstract interface for vector stores.
    #
    # Implementations manage a collection of (embedding, metadata) pairs and
    # support similarity search.
    class Base
      # Add a document with its vector embedding.
      #
      # @param id        [String]  unique document identifier
      # @param embedding [Array<Float>] vector embedding
      # @param metadata  [Hash]    arbitrary metadata (e.g. the original message object)
      def add(id:, embedding:, metadata: {})
        raise NotImplementedError, "#{self.class}#add is not implemented"
      end

      # Return the k most similar documents to the query embedding.
      #
      # @param query_embedding [Array<Float>]
      # @param k               [Integer]       number of results
      # @return [Array<Hash>] each element: { id:, score:, metadata: }
      def search(query_embedding:, k: 5)
        raise NotImplementedError, "#{self.class}#search is not implemented"
      end

      # Remove a single document by id.
      #
      # @param id [String] document identifier
      def remove(id:)
        raise NotImplementedError, "#{self.class}#remove is not implemented"
      end

      # Remove all documents.
      def clear
        raise NotImplementedError, "#{self.class}#clear is not implemented"
      end
    end
  end
end
