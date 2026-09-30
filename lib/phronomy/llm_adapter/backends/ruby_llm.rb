# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Default LLMAdapter SPI implementation backed by RubyLLM.
    #
    # The synchronous +chat.ask+ / +chat.complete+ calls are invoked through the
    # framework-owned execution client, so adapter consumers do not need to
    # manage worker pools themselves. This implementation depends only on the
    # synchronous {LLMAdapter::Base} contract.
    #
    # @example Explicitly configuring this adapter
    #   Phronomy.configure do |c|
    #     c.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
    #   end
    #
    # @api public
    class RubyLLM < Base
      def identity
        super.merge("sdk_version" => ::RubyLLM::VERSION).freeze
      end

      def input_budget(model_config)
        config = model_config.to_h.transform_keys(&:to_s)
        return nil unless config["model"]

        model = ::RubyLLM.models.find(config["model"], provider: config["provider"])
        limit = model&.context_window
        return nil unless limit.is_a?(Integer) && limit.positive?

        Phronomy::LlmContextWindow::TokenBudget.new(max_input_tokens: limit)
      rescue ::RubyLLM::ModelNotFoundError
        nil
      rescue => error
        raise_provider_error(error)
      end

      def build_chat(config)
        options = {}
        options[:model] = config["model"] if config["model"]
        if config["provider"]
          options[:provider] = config["provider"].to_sym
          options[:assume_model_exists] = true
        end
        chat = ::RubyLLM.chat(**options)
        chat.with_temperature(config["temperature"]) if config["temperature"]
        chat.with_max_output_tokens(config["max_output_tokens"]) if config["max_output_tokens"]
        chat
      rescue => error
        raise_provider_error(error)
      end

      def configure_chat(chat, system:, cache:, tools:, messages:)
        chat.with_instructions(system, cache_until_here: cache) if system
        tools.each { |tool| chat.with_tools(tool) }
        messages.each { |message| chat.messages << message }
        chat
      rescue => error
        raise_provider_error(error)
      end

      def message(**attributes)
        ::RubyLLM::Message.new(**attributes)
      rescue => error
        raise_provider_error(error)
      end

      def tool_call(**attributes)
        ::RubyLLM::ToolCall.new(**attributes)
      rescue => error
        raise_provider_error(error)
      end

      # Delegates to +chat.ask(message)+ or +chat.complete+ when message is nil.
      #
      # Passing +nil+ for +message+ is used by the ReAct loop for continuation
      # turns where the user message has already been added to the chat history
      # (for example after a Tool result).
      #
      # @param chat    [Object]      RubyLLM chat session
      # @param message [String, nil] user message, or nil to continue the chat
      # @param config  [Hash]        invocation config (not used directly here)
      # @return [Object] RubyLLM response
      # @api public
      def complete(chat, message, config: {})
        message ? chat.ask(message) : chat.complete
      rescue => error
        raise_provider_error(error)
      end

      # Delegates to +chat.ask(message) { |chunk| ... }+ or +chat.complete(&block)+
      # when message is nil.
      #
      # @param chat    [Object]      RubyLLM chat session
      # @param message [String, nil] user message, or nil to continue the chat
      # @param config  [Hash]        invocation config
      # @yield [chunk] streaming chunk forwarded from RubyLLM
      # @return [Object] RubyLLM response
      # @api public
      def stream(chat, message, config: {}, &block)
        message ? chat.ask(message, &block) : chat.complete(&block)
      rescue => error
        raise_provider_error(error)
      end

      private

      # Called while the original exception is active, preserving #cause.
      # Cancellation, recovery, policy and application errors retain their identity.
      def raise_provider_error(error)
        case error
        when ::RubyLLM::RateLimitError
          raise Phronomy::RateLimitError, error.message
        when ::RubyLLM::UnauthorizedError, ::RubyLLM::ForbiddenError
          raise Phronomy::AuthenticationError, error.message
        when ::RubyLLM::ContextLengthExceededError
          raise Phronomy::ContextLengthError, error.message
        when ::RubyLLM::Error
          raise Phronomy::TransportError, error.message
        else
          raise error
        end
      end
    end
  end
end
