# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Abstract base class for LLM adapters.
    #
    # Subclasses must implement {#complete} and {#stream}. The adapter or the
    # underlying provider client owns transport timeout, retry, backoff, and
    # rate-limit behavior. Phronomy supplies cooperative cancellation and
    # isolates synchronous provider calls in {OffloadPool}.
    #
    # The agent pipeline calls {#complete_async} / {#stream_async} which wrap
    # those methods in an {OffloadPool} submission.
    class Base
      # Performs a blocking (non-streaming) LLM completion.
      # Implementors must call +chat.ask(message)+ (or equivalent) and
      # return the response object.
      #
      # @param chat    [Object] the configured chat session object
      # @param message [String] the user message
      # @param config  [Hash] invocation config (e.g. +:cancellation_token+)
      # @return [Object] LLM response object
      # @raise [NotImplementedError]
      # @api private
      def complete(chat, message, config: {})
        raise NotImplementedError, "#{self.class}#complete is not implemented"
      end

      # Performs a blocking streaming LLM completion.
      # Implementors must call +chat.ask(message) { |chunk| block.call(chunk) }+
      # (or equivalent) and return the response object.
      #
      # @param chat    [Object] the configured chat session object
      # @param message [String] the user message
      # @param config  [Hash] invocation config
      # @yield [chunk] streaming chunk from the LLM
      # @return [Object] LLM response object
      # @raise [NotImplementedError]
      # @api private
      def stream(chat, message, config: {}, &block)
        raise NotImplementedError, "#{self.class}#stream is not implemented"
      end

      # Submits a non-streaming LLM call to {OffloadPool} and returns
      # an {OffloadPool::PendingOperation}.
      #
      # Transport timeout and retry remain the responsibility of the adapter or
      # provider client; Phronomy does not attach an additional operation timeout.
      #
      # @param chat    [Object] configured chat session
      # @param message [String] user message
      # @param config  [Hash] invocation config
      # @param pool    [OffloadPool] pool to submit to
      # @return [OffloadPool::PendingOperation]
      # @api private
      def complete_async(chat, message, config: {}, pool: default_pool)
        token = config[:cancellation_token]
        pool.submit(cancellation_token: token, on_full: :raise) do
          complete(chat, message, config: config)
        end
      end

      # Submits a streaming LLM call to {OffloadPool} and returns
      # an {OffloadPool::PendingOperation}.
      #
      # The block is invoked on an OffloadPool worker thread. Agent code must
      # pass only a lightweight internal sink that posts a value to EventLoop;
      # Application callbacks must never be passed directly to this method.
      #
      # Transport timeout and retry remain the responsibility of the adapter or
      # provider client; Phronomy does not attach an additional operation timeout.
      #
      # @yield [chunk] streaming chunk on the worker thread
      # @return [OffloadPool::PendingOperation]
      # @api private
      def stream_async(chat, message, config: {}, pool: default_pool, &block)
        raise ArgumentError, "stream_async requires a block" unless block

        token = config[:cancellation_token]
        pool.submit(cancellation_token: token, on_full: :raise) do
          stream(chat, message, config: config) do |chunk|
            token&.raise_if_cancelled!("invocation cancelled during streaming")
            block.call(chunk)
          end
        end
      end

      private

      def default_pool
        Phronomy::Runtime.instance.offload
      end
    end
  end
end
