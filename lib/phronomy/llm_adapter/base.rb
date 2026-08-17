# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Beta extension SPI for LLM call adapters.
    #
    # External adapters implement {#complete} and {#stream}. The adapter or the
    # underlying provider client owns transport timeout, retry, backoff, and
    # rate-limit behavior. Phronomy owns cooperative cancellation and isolates
    # synchronous provider calls in {OffloadPool}.
    #
    # The Agent pipeline calls the framework-owned {#complete_async} and
    # {#stream_async} wrappers. Adapter implementers do not need to depend on
    # EventLoop, FSMSession, OffloadPool, AgentInvocation, or ExecutionCoordinator.
    #
    # The current input to this SPI is the configured/materialized chat runtime
    # object. Formalizing this SPI therefore does not imply a provider-neutral
    # replacement for RubyLLMMaterializer.
    #
    # @api public
    class Base
      # Performs a blocking (non-streaming) LLM completion.
      #
      # Implementors call the configured chat/runtime client and return its
      # response object. Transport/retry policy remains adapter-owned.
      #
      # @param chat    [Object] the configured/materialized chat runtime object
      # @param message [String, nil] user message, or nil to continue without adding a new user turn
      # @param config  [Hash] invocation config (e.g. +:cancellation_token+)
      # @return [Object] LLM response object
      # @raise [NotImplementedError]
      # @api public
      def complete(chat, message, config: {})
        raise NotImplementedError, "#{self.class}#complete is not implemented"
      end

      # Performs a blocking streaming LLM completion.
      #
      # @param chat    [Object] the configured/materialized chat runtime object
      # @param message [String, nil] user message, or nil to continue without adding a new user turn
      # @param config  [Hash] invocation config
      # @yield [chunk] streaming chunk from the LLM
      # @return [Object] LLM response object
      # @raise [NotImplementedError]
      # @api public
      def stream(chat, message, config: {}, &block)
        raise NotImplementedError, "#{self.class}#stream is not implemented"
      end

      # Submits a non-streaming LLM call to {OffloadPool}.
      #
      # Transport timeout and retry remain the responsibility of the adapter or
      # provider client; Phronomy does not attach an additional operation timeout.
      #
      # @return [Phronomy::Task] caller-facing completion handle
      # @api private
      def complete_async(chat, message, config: {}, pool: default_pool)
        token = config[:cancellation_token]
        pool.submit(cancellation_token: token, on_full: :raise) do
          complete(chat, message, config: config)
        end
      end

      # Submits a streaming LLM call to {OffloadPool}.
      #
      # The block is invoked on an OffloadPool worker thread. Agent code must pass
      # only a lightweight internal sink that posts a value to EventLoop;
      # application callbacks must never be passed directly to this method.
      #
      # @yield [chunk] streaming chunk on the worker thread
      # @return [Phronomy::Task] caller-facing completion handle
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
