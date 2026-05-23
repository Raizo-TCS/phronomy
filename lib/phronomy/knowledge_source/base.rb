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
      # @param query              [String, nil]                    the current user input used to select relevant chunks
      # @param cancellation_token [Phronomy::CancellationToken, nil] optional token; raises CancellationError when cancelled
      # @return [Array<Hash>] array of { content: String, type: Symbol }
      def fetch(query: nil, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        raise NotImplementedError, "#{self.class}#fetch is not implemented"
      end

      # Returns true when this source's content is considered static (i.e. does
      # not change between agent invocations). Static sources are eligible for
      # fingerprint-based caching in ContextVersionCache.
      #
      # Override in subclasses that return fixed content.
      #
      # @return [Boolean]
      def static?
        false
      end
    end
  end
end
