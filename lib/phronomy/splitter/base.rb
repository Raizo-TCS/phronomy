# frozen_string_literal: true

module Phronomy
  module Splitter
    # Abstract base class for text splitters.
    #
    # A splitter takes a single document hash (or plain text) and returns an
    # array of smaller chunk documents:
    #
    #   [{ text: String, metadata: Hash }, ...]
    #
    # Subclasses must implement {#split}.
    class Base
      # Split +document+ into an array of chunk documents.
      #
      # @param document [Hash, String]
      #   Either a document hash (<tt>{ text: String, metadata: Hash }</tt>)
      #   returned by a Loader, or a plain String.
      # @return [Array<Hash>] array of <tt>{ text: String, metadata: Hash }</tt>
      # @raise [NotImplementedError] when not overridden by a subclass
      # @api public
      def split(document)
        raise NotImplementedError, "#{self.class}#split is not implemented"
      end

      # Convenience method: split an array of documents.
      #
      # @param documents [Array<Hash, String>]
      # @return [Array<Hash>]
      # @api public
      def split_all(documents)
        documents.flat_map { |doc| split(doc) }
      end

      private

      # Normalise a document-or-string argument into {text:, metadata:}.
      def normalise(document)
        case document
        when Hash then {text: document[:text].to_s, metadata: document.fetch(:metadata, {})}
        when String then {text: document, metadata: {}}
        else raise ArgumentError, "document must be a Hash or String, got #{document.class}"
        end
      end
    end
  end
end
