# frozen_string_literal: true

module Phronomy
  module VectorStore
    module Embeddings
      # Abstract interface for embedding adapters.
      #
      # Concrete implementations must override {#embed} and return a vector
      # as an +Array<Float>+.
      class Base
        # Embed the given text and return a vector representation.
        #
        # @param text               [String]                         the text to embed
        # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
        # @return [Array<Float>] the embedding vector
        # @api public
        def embed(text, cancellation_token = nil)
          cancellation_token&.raise_if_cancelled!
          raise NotImplementedError, "#{self.class}#embed is not implemented"
        end

        # Submits an {#embed} call to {OffloadPool} and returns an
        # {OffloadPool::PendingOperation}.
        #
        # @param text               [String]
        # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
        # @param timeout            [Numeric, nil] seconds before the operation is abandoned
        # @return [OffloadPool::PendingOperation]
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
