# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Offloads the entire operation, including SDK initialization and decoding.
    # Construction does not start a Runtime.
    # @api private
    class AsyncClient
      # @api private
      def initialize(adapter:, pool: nil, submitter: Phronomy::Execution)
        @adapter = adapter
        @pool = pool
        @submitter = submitter
      end

      # @api private
      def complete_async(request, cancellation_token: nil, pool: @pool)
        submit(pool, cancellation_token) do
          @adapter.complete(request, cancellation_token: cancellation_token)
        end
      end

      # The block is an internal event sink, never an Application callback.
      # @api private
      def stream_async(request, cancellation_token: nil, pool: @pool, &block)
        raise ArgumentError, "stream_async requires a block" unless block
        submit(pool, cancellation_token) do
          @adapter.stream(request, cancellation_token: cancellation_token) do |chunk|
            cancellation_token&.raise_if_cancelled!
            block.call(chunk)
          end
        end
      end

      private

      def submit(pool, cancellation_token, &operation)
        if pool
          Phronomy::Execution.submit(pool: pool, cancellation_token: cancellation_token,
            on_full: :raise, &operation)
        else
          @submitter.submit(cancellation_token: cancellation_token, on_full: :raise, &operation)
        end
      end
    end
  end
end
