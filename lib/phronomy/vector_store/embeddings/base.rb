# frozen_string_literal: true

module Phronomy
  module VectorStore
    module Embeddings
      # Public extension SPI for embedding adapters.
      #
      # Concrete implementations override {#embed}. The framework supplies
      # asynchronous execution through a separate client. This synchronous SPI
      # requires no execution engine, pool, or asynchronous implementation.
      #
      # @api public
      class Base
        # Embed the given text and return a vector representation.
        #
        # @param text               [String] the text to embed
        # @param cancellation_token [#raise_if_cancelled!, nil] cooperative cancellation signal
        # @return [Array<Float>] the embedding vector
        # @api public
        def embed(text, cancellation_token = nil)
          cancellation_token&.raise_if_cancelled!
          raise NotImplementedError, "#{self.class}#embed is not implemented"
        end
      end
    end
  end
end
