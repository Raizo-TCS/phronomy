# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Beta extension SPI for LLM call adapters.
    #
    # External adapters implement {#complete} and {#stream}. The adapter or the
    # underlying provider client owns transport timeout, retry, backoff, and
    # rate-limit behavior. The framework supplies asynchronous execution outside
    # this synchronous contract. Adapter implementers provide only these two
    # methods and do not depend on the execution engine or its clients.
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
    end
  end
end
