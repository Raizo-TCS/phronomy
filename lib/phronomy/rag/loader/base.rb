# frozen_string_literal: true

module Phronomy
  module RAG
    module Loader
      # Abstract base class for document loaders.
      #
      # A loader converts an external source (file path, URL, etc.) into an
      # Array of document hashes understood by the rest of the pipeline:
      #
      #   [{ text: String, metadata: Hash }, ...]
      #
      # Subclasses must implement {#load}.
      class Base
        # Load documents from +source+ and return an array of document hashes.
        #
        # @param source [String] file path, URL, or other source identifier
        # @return [Array<Hash>] array of <tt>{ text: String, metadata: Hash }</tt>
        # @raise [NotImplementedError] when not overridden by a subclass
        # @api public
        def load(source)
          raise NotImplementedError, "#{self.class}#load is not implemented"
        end
      end
    end
  end
end
