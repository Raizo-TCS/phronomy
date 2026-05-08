# frozen_string_literal: true

module Phronomy
  module KnowledgeSource
    # Abstract base class for all KnowledgeSource implementations.
    #
    # Subclasses must implement #fetch(query:) and return an Array of chunk Hashes.
    # Each chunk Hash must contain:
    #   :content [String]  the text to inject into the context
    #   :type    [Symbol]  semantic tag (e.g. :static, :rag, :entity)
    class Base
      # Retrieve knowledge chunks relevant to the given query.
      #
      # @param query [String, nil] the current user input used to select relevant chunks
      # @return [Array<Hash>] array of { content: String, type: Symbol }
      def fetch(query: nil)
        raise NotImplementedError, "#{self.class}#fetch is not implemented"
      end
    end
  end
end
