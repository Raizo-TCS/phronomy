# frozen_string_literal: true

module Phronomy
  module VectorStore
    module Embeddings
      # Framework-owned asynchronous execution of a synchronous embedding adapter.
      #
      # Construction starts no Runtime. Each operation uses the current default
      # pool unless a caller-owned pool was injected. Timeout includes queue wait
      # and settles the result without forcibly interrupting an executing adapter.
      #
      # @api public
      class AsyncClient
        # @param adapter [Embeddings::Base] synchronous embedding adapter
        # @param pool [Concurrency::OffloadPool, nil] optional execution pool
        # @api public
        def initialize(adapter:, pool: nil)
          @adapter = adapter
          @pool = pool
        end

        # Submits a synchronous embed call without waiting for queue capacity.
        #
        # @param text [String]
        # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
        # @param timeout [Numeric, nil] operation-wide submit timeout
        # @return [Phronomy::TaskResult] the pool's original completion handle
        # @api public
        def embed_async(text, cancellation_token = nil, timeout: nil)
          default_pool.submit(
            timeout: timeout,
            cancellation_token: cancellation_token,
            on_full: :raise
          ) do
            @adapter.embed(text, cancellation_token)
          end
        end

        private

        def default_pool
          @pool || Phronomy::Runtime.instance.offload
        end
      end
    end
  end
end
