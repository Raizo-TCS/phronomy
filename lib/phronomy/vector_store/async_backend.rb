# frozen_string_literal: true

module Phronomy
  module VectorStore
    # Mixin that defines the async interface for VectorStore backends.
    #
    # Mixing this module into a VectorStore class provides three choices:
    #
    # 1. **Do nothing** — inherits default implementations from {VectorStore::Base}
    #    that route through {OffloadPool}.
    #
    # 2. **Override selectively** — override only the async methods where the
    #    backend has a native async driver, while the remaining methods fall back
    #    to the pool.
    #
    # 3. **Implement all natively** — override all async methods to avoid pool
    #    allocation entirely.
    #
    # @example Native async search (no pool worker thread allocated)
    #   class MyFastStore < Phronomy::VectorStore::Base
    #     include Phronomy::VectorStore::AsyncBackend
    #
    #     def search_async(query_embedding:, k: 5, cancellation_token: nil, timeout: nil)
    #       # Returns a PendingOperation backed by a native async driver.
    #       native_async_search(query_embedding, k)
    #     end
    #   end
    #
    # @api public
    module AsyncBackend
      # Async variant of {VectorStore::Base#add}.
      #
      # Submits the add call to {OffloadPool} by default.
      # Override to use a native async driver.
      #
      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [OffloadPool::PendingOperation]
      # @api public
      def add_async(id:, embedding:, metadata: {}, cancellation_token: nil, timeout: nil)
        Phronomy::Runtime.instance.offload.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          add(id: id, embedding: embedding, metadata: metadata, cancellation_token: cancellation_token)
        end
      end

      # Async variant of {VectorStore::Base#search}.
      #
      # Submits the search call to {OffloadPool} by default.
      # Override to use a native async driver.
      #
      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [OffloadPool::PendingOperation]
      # @api public
      def search_async(query_embedding:, k: 5, cancellation_token: nil, timeout: nil)
        Phronomy::Runtime.instance.offload.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          search(query_embedding: query_embedding, k: k, cancellation_token: cancellation_token)
        end
      end

      # Async variant of {VectorStore::Base#remove}.
      #
      # Submits the remove call to {OffloadPool} by default.
      # Override to use a native async driver.
      #
      # @param id                 [String]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [OffloadPool::PendingOperation]
      # @api public
      def remove_async(id:, cancellation_token: nil, timeout: nil)
        Phronomy::Runtime.instance.offload.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          remove(id: id)
        end
      end

      # Async variant of {VectorStore::Base#clear}.
      #
      # Submits the clear call to {OffloadPool} by default.
      # Override to use a native async driver.
      #
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [OffloadPool::PendingOperation]
      # @api public
      def clear_async(cancellation_token: nil, timeout: nil)
        Phronomy::Runtime.instance.offload.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          clear
        end
      end
    end
  end
end
