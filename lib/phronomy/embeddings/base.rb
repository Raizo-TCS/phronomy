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
      # @param text               [String]                         the text to embed
      # @param cancellation_token [Phronomy::CancellationToken, nil] optional; raises CancellationError when cancelled
      # @return [Array<Float>] the embedding vector
      # @api public
      def embed(text, cancellation_token = nil)
        cancellation_token&.raise_if_cancelled!
        raise NotImplementedError, "#{self.class}#embed is not implemented"
      end
    end
  end
end
