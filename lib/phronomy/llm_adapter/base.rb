# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Abstract base class for LLM adapters.
    #
    # Subclasses must implement {#complete} and {#stream}. The adapter or the
    # underlying provider client owns transport timeout, retry, backoff, and
    # rate-limit behavior. Phronomy only supplies cooperative cancellation and
    # isolates blocking calls in {BlockingAdapterPool}.
    #
    # The agent pipeline calls {#complete_async} / {#stream_async} which wrap
    # those methods in a {BlockingAdapterPool} submission.
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

      # Submits a non-streaming LLM call to {BlockingAdapterPool} and returns
      # a {BlockingAdapterPool::PendingOperation}.
      #
      # Transport timeout and retry remain the responsibility of the adapter or
      # provider client; Phronomy does not attach an additional operation timeout.
      #
      # @param chat    [Object] configured chat session
      # @param message [String] user message
      # @param config  [Hash] invocation config
      # @param pool    [BlockingAdapterPool] pool to submit to
      # @return [BlockingAdapterPool::PendingOperation]
      # @api private
      def complete_async(chat, message, config: {}, pool: default_pool)
        token = config[:cancellation_token]
        pool.submit(cancellation_token: token) do
          complete(chat, message, config: config)
        end
      end

      # Submits a streaming LLM call to {BlockingAdapterPool} and returns
      # a {BlockingAdapterPool::PendingOperation}.
      #
      # When +enqueue_to:+ is given, streaming chunks are pushed into that
      # {AsyncQueue} from the worker thread instead of being passed directly
      # to the caller's block. The queue is closed (via +ensure+) after the LLM
      # call finishes so the consumer's drain loop terminates naturally.
      # This keeps user-supplied blocks off the blocking-pool worker thread.
      #
      # When +enqueue_to:+ is nil and a block is given, the block is invoked
      # directly from the worker thread (legacy behaviour, preserved for
      # backward compatibility).
      #
      # Transport timeout and retry remain the responsibility of the adapter or
      # provider client; Phronomy does not attach an additional operation timeout.
      #
      # @param chat       [Object] configured chat session
      # @param message    [String] user message
      # @param config     [Hash] invocation config
      # @param pool       [BlockingAdapterPool] pool to submit to
      # @param enqueue_to [AsyncQueue, nil] when set, push chunks here instead of
      #   calling the block on the worker thread
      # @yield [chunk] streaming chunk — only used when +enqueue_to:+ is nil
      # @return [BlockingAdapterPool::PendingOperation]
      # @api private
      def stream_async(chat, message, config: {}, pool: default_pool, enqueue_to: nil, &block)
        token = config[:cancellation_token]
        if enqueue_to
          pool.submit(cancellation_token: token) do
            stream(chat, message, config: config) do |chunk|
              enqueue_to.push(chunk)
            end
          ensure
            enqueue_to.close
          end
        else
          pool.submit(cancellation_token: token) do
            stream(chat, message, config: config, &block)
          end
        end
      end

      private

      def default_pool
        Phronomy::Runtime.instance.blocking_io
      end
    end
  end
end
