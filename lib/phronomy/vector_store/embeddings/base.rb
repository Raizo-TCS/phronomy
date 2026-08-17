# frozen_string_literal: true

module Phronomy
  module VectorStore
    module Embeddings
      # Public extension SPI for embedding adapters.
      #
      # Concrete implementations override {#embed}. Phronomy owns the async
      # bridge: {#embed_async} routes the synchronous implementation through the
      # bounded OffloadPool and returns a {Phronomy::Task}.
      #
      # @api public
      class Base
        # Embed the given text and return a vector representation.
        #
        # @param text               [String] the text to embed
        # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
        # @return [Array<Float>] the embedding vector
        # @api public
        def embed(text, cancellation_token = nil)
          cancellation_token&.raise_if_cancelled!
          raise NotImplementedError, "#{self.class}#embed is not implemented"
        end

        # Submits an {#embed} call to {OffloadPool}.
        #
        # @param text               [String]
        # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
        # @param timeout            [Numeric, nil] operation-wide submit timeout
        # @return [Phronomy::Task]
        # @api public
        def embed_async(text, cancellation_token = nil, timeout: nil)
          Phronomy::Runtime.instance.offload.submit(
            timeout: timeout,
            cancellation_token: cancellation_token,
            on_full: :raise
          ) do
            embed(text, cancellation_token)
          end
        end
      end
    end
  end
end
