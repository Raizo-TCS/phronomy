# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Abstract base class for LLM adapters.
    #
    # Subclasses must implement {#complete} and {#stream}.
    # The agent pipeline calls {#complete_async} / {#stream_async} which wrap
    # those methods in a {BlockingAdapterPool} submission.
    class Base
      # Performs a blocking (non-streaming) LLM completion.
      # Implementors must call +chat.ask(message)+ (or equivalent) and
      # return the response object.
      #
      # @param chat    [Object] the configured chat session object
      # @param message [String] the user message
      # @param config  [Hash]  the invocation config (e.g. +:cancellation_token+)
      # @return [Object] LLM response object
      # @raise [NotImplementedError]
      def complete(chat, message, config: {})
        raise NotImplementedError, "#{self.class}#complete is not implemented"
      end

      # Performs a blocking streaming LLM completion.
      # Implementors must call +chat.ask(message) { |chunk| block.call(chunk) }+
      # (or equivalent) and return the response object.
      #
      # @param chat    [Object] the configured chat session object
      # @param message [String] the user message
      # @param config  [Hash]  the invocation config
      # @yield [chunk] streaming chunk from the LLM
      # @return [Object] LLM response object
      # @raise [NotImplementedError]
      def stream(chat, message, config: {}, &block)
        raise NotImplementedError, "#{self.class}#stream is not implemented"
      end

      # Submits a non-streaming LLM call to {BlockingAdapterPool} and returns
      # a {BlockingAdapterPool::PendingOperation}.
      #
      # @param chat    [Object] configured chat session
      # @param message [String] user message
      # @param config  [Hash]  invocation config
      # @param pool    [BlockingAdapterPool] pool to submit to
      # @return [BlockingAdapterPool::PendingOperation]
      def complete_async(chat, message, config: {}, pool: default_pool)
        token   = config[:cancellation_token]
        timeout = config[:llm_timeout]
        pool.submit(timeout: timeout, cancellation_token: token) do
          complete(chat, message, config: config)
        end
      end

      # Submits a streaming LLM call to {BlockingAdapterPool} and returns
      # a {BlockingAdapterPool::PendingOperation}.
      #
      # @param chat    [Object] configured chat session
      # @param message [String] user message
      # @param config  [Hash]  invocation config
      # @param pool    [BlockingAdapterPool] pool to submit to
      # @yield [chunk] streaming chunk (called from the worker thread)
      # @return [BlockingAdapterPool::PendingOperation]
      def stream_async(chat, message, config: {}, pool: default_pool, &block)
        token   = config[:cancellation_token]
        timeout = config[:llm_timeout]
        pool.submit(timeout: timeout, cancellation_token: token) do
          stream(chat, message, config: config, &block)
        end
      end

      private

      def default_pool
        Phronomy::Runtime.instance.blocking_io
      end
    end
  end
end
