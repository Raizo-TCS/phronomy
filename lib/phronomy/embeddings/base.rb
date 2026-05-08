# frozen_string_literal: true

module Phronomy
  module Embeddings
    # Abstract interface for embedding adapters.
    #
    # Concrete implementations must override {#embed} and return a vector
    # as an +Array<Float>+.
    class Base
      # Embed the given text and return a vector representation.
      #
      # @param text [String] the text to embed
      # @return [Array<Float>] the embedding vector
      def embed(text)
        raise NotImplementedError, "#{self.class}#embed is not implemented"
      end
    end
  end
end
