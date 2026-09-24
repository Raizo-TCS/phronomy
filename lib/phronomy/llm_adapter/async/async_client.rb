# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Framework-owned asynchronous execution of a synchronous LLM adapter.
    #
    # The adapter owns provider transport timeout, retry and rate-limit policy.
    # This client preserves non-waiting pool admission and returns the original
    # TaskResult. Constructing a client never starts the default Runtime.
    #
    # @api private
    class AsyncClient
      # @param adapter [LLMAdapter::Base] synchronous call adapter
      # @param pool [Concurrency::OffloadPool, nil] optional caller-owned pool
      # @api private
      def initialize(adapter:, pool: nil)
        @adapter = adapter
        @pool = pool
      end

      # Submits a non-streaming call without adding an operation timeout.
      #
      # @return [Phronomy::TaskResult] the pool's original completion handle
      # @api private
      def complete_async(chat, message, config: {}, pool: default_pool)
        token = config[:cancellation_token]
        pool.submit(cancellation_token: token, on_full: :raise) do
          @adapter.complete(chat, message, config: config)
        end
      end

      # Submits a streaming call. The supplied block runs on a pool worker.
      # Agent code supplies only an internal sink that posts to EventLoop;
      # application callbacks must not be passed directly to this method.
      #
      # @yield [chunk] streaming chunk on the worker thread
      # @return [Phronomy::TaskResult] the pool's original completion handle
      # @api private
      def stream_async(chat, message, config: {}, pool: default_pool, &block)
        raise ArgumentError, "stream_async requires a block" unless block

        token = config[:cancellation_token]
        pool.submit(cancellation_token: token, on_full: :raise) do
          @adapter.stream(chat, message, config: config) do |chunk|
            token&.raise_if_cancelled!("invocation cancelled during streaming")
            block.call(chunk)
          end
        end
      end

      private

      def default_pool
        @pool || Phronomy::Runtime.instance.offload
      end
    end
  end
end
