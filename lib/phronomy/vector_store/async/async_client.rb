# frozen_string_literal: true

module Phronomy
  module VectorStore
    # Framework-owned asynchronous execution of a synchronous vector backend.
    #
    # Backend authors implement only Base's synchronous operations. Applications
    # use this client for asynchronous calls. Admission never waits for queue
    # capacity; accepted calls return the pool's original TaskResult. Timeout
    # includes queue wait and settles the result without interrupting running I/O.
    # Construction does not start Runtime; the current default pool is resolved
    # for each operation. An injected pool remains owned by its caller.
    #
    # @api public
    class AsyncClient
      # @param backend [VectorStore::Base] synchronous vector store
      # @param pool [Concurrency::OffloadPool, nil] optional execution pool
      # @api public
      def initialize(backend:, pool: nil)
        @backend = backend
        @pool = pool
      end

      # Async variant of {VectorStore::Base#add}.
      #
      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::TaskResult]
      # @api public
      def add_async(id:, embedding:, metadata: {}, cancellation_token: nil, timeout: nil)
        default_pool.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          @backend.add(id: id, embedding: embedding, metadata: metadata, cancellation_token: cancellation_token)
        end
      end

      # Async variant of {VectorStore::Base#search}.
      #
      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::TaskResult]
      # @api public
      def search_async(query_embedding:, k: 5, cancellation_token: nil, timeout: nil)
        default_pool.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          @backend.search(query_embedding: query_embedding, k: k, cancellation_token: cancellation_token)
        end
      end

      # Async variant of {VectorStore::Base#remove}.
      #
      # @param id                 [String]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::TaskResult]
      # @api public
      def remove_async(id:, cancellation_token: nil, timeout: nil)
        default_pool.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          @backend.remove(id: id)
        end
      end

      # Async variant of {VectorStore::Base#clear}.
      #
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::TaskResult]
      # @api public
      def clear_async(cancellation_token: nil, timeout: nil)
        default_pool.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          @backend.clear
        end
      end

      private

      def default_pool
        @pool || Phronomy::Runtime.instance.offload
      end
    end
  end
end
