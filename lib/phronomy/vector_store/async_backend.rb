# frozen_string_literal: true

module Phronomy
  module VectorStore
    # Framework-owned async convenience methods for VectorStore backends.
    #
    # The backend extension contract is the synchronous interface defined by
    # {VectorStore::Base}: add/search/remove/clear/size. These async convenience
    # methods are inherited by backends and route that synchronous work through
    # Phronomy's bounded {OffloadPool}. This keeps OS-thread creation, queue
    # backpressure, submit timeout/cancellation, and completion semantics owned by
    # the framework rather than by each backend.
    #
    # A future genuine native-async backend may adapt its completion into a
    # {Phronomy::Task} without an OffloadPool worker, but native async override is
    # not part of the current backend SPI.
    #
    # @api private
    module AsyncBackend
      # Async variant of {VectorStore::Base#add}.
      #
      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::Task]
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
      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::Task]
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
      # @param id                 [String]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::Task]
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
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @param timeout            [Numeric, nil]
      # @return [Phronomy::Task]
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
