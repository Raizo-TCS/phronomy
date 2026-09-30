# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Beta extension SPI for LLM call adapters.
    #
    # Adapters own chat construction, model information, input materialization
    # and provider failure translation, as well as completion and streaming.
    # The asynchronous client owns worker submission. No provider SDK is required
    # to load this contract.
    #
    # @api public
    class Base
      # Adapter identity is saved with canonical context to reject incompatible replay.
      def identity
        {"adapter_name" => self.class.name}.freeze
      end

      # Unknown model capacity is allowed; the application may supply its own policy.
      def input_budget(model_config)
        nil
      end

      def build_chat(model_config)
        raise NotImplementedError, "#{self.class}#build_chat is not implemented"
      end

      def configure_chat(chat, system:, cache:, tools:, messages:)
        raise NotImplementedError, "#{self.class}#configure_chat is not implemented"
      end

      def message(**attributes)
        raise NotImplementedError, "#{self.class}#message is not implemented"
      end

      def tool_call(**attributes)
        raise NotImplementedError, "#{self.class}#tool_call is not implemented"
      end

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
