# frozen_string_literal: true

require "ruby_llm"

module Phronomy
  module LLMAdapter
    # SDK objects are operation-local. Only Phronomy request/result values cross
    # the backend boundary; a Tool definition never contains executable work.
    # @api public
    class RubyLLM < Base
      ToolsRequested = Class.new(StandardError) do
        attr_reader :message_value
        def initialize(message_value)
          @message_value = message_value
          super("assistant requested Tools")
        end
      end
      private_constant :ToolsRequested

      # @api public
      def identity
        super.merge("sdk_version" => ::RubyLLM::VERSION).freeze
      end

      # @api public
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

      protected

      # @api public
      def perform_complete(request, cancellation_token:)
        execute_request(request, cancellation_token)
      end

      # @api public
      def perform_stream(request, cancellation_token:, &block)
        execute_request(request, cancellation_token, &block)
      end

      private

      def execute_request(request, token)
        callback_error = nil
        chat = build_chat(request)
        token&.raise_if_cancelled!
        chat.after_message do |message|
          raise ToolsRequested.new(message) if message.tool_call?
        end
        response = if block_given?
          sink = proc do |chunk|
            token&.raise_if_cancelled!
            value = stream_value(chunk)
            begin
              yield value
            rescue => error
              callback_error = error
              raise
            end
          end
          request.message ? chat.ask(request.message, &sink) : chat.complete(&sink)
        else
          request.message ? chat.ask(request.message) : chat.complete
        end
        response_value(response)
      rescue ToolsRequested => requested
        response_value(requested.message_value)
      rescue => error
        raise error if error.equal?(callback_error)
        raise_provider_error(error)
      end

      def build_chat(request)
        config = request.model_config
        options = {}
        options[:model] = config["model"] if config["model"]
        if config["provider"]
          options[:provider] = config["provider"].to_sym
          options[:assume_model_exists] = config.fetch("assume_model_exists", true)
        elsif config.key?("assume_model_exists")
          options[:assume_model_exists] = config["assume_model_exists"]
        end
        chat = ::RubyLLM.chat(**options)
        chat.with_temperature(config["temperature"]) if config["temperature"]
        chat.with_max_output_tokens(config["max_output_tokens"]) if config["max_output_tokens"]
        if request.system
          chat.with_instructions(request.system, cache_until_here: config["cache_instructions"])
        end
        request.tools.each { |definition| chat.with_tools(tool_declaration(definition)) }
        request.messages.each { |value| chat.messages << sdk_message(value) }
        chat
      end

      def tool_declaration(definition)
        name = definition.fetch("name")
        klass = Class.new(::RubyLLM::Tool) do
          define_singleton_method(:tool_name) { name }
          define_method(:execute) do |**_arguments|
            raise InvalidResultError, "SDK attempted to execute a declaration-only Tool"
          end
        end
        klass.description(definition.fetch("description"))
        klass.parameters(definition.fetch("parameters_schema"))
        klass.provider_options(definition.fetch("provider_options", {}))
        klass
      end

      def sdk_message(value)
        calls = value.tool_calls.to_h do |call|
          [call.id, ::RubyLLM::ToolCall.new(id: call.id, name: call.name,
            arguments: call.arguments, thought_signature: call.metadata["thought_signature"])]
        end
        content = value.content
        content = JSON.generate(content) if content.is_a?(Hash) || content.is_a?(Array)
        content = "" if value.role == :assistant && content.nil? && !calls.empty?
        ::RubyLLM::Message.new(role: value.role, content: content,
          tool_calls: calls.empty? ? nil : calls, tool_call_id: value.tool_call_id,
          model: value.metadata["model_id"])
      end

      def response_value(message)
        unless message.respond_to?(:content) && message.respond_to?(:role) && message.role.to_sym == :assistant
          raise InvalidResultError, "provider returned an invalid assistant message"
        end
        raw_calls = message.tool_calls if message.respond_to?(:tool_calls)
        calls = raw_calls.is_a?(Hash) ? raw_calls.values : (raw_calls || [])
        raise InvalidResultError, "provider returned invalid Tool calls" unless calls.is_a?(Array)
        calls = calls.map do |call|
          metadata = {}
          if call.respond_to?(:thought_signature) && call.thought_signature
            metadata["thought_signature"] = call.thought_signature
          end
          Phronomy::Tool::CallRequest.new(id: call.id, name: call.name,
            arguments: call.arguments, metadata: metadata)
        end
        tokens = message.tokens if message.respond_to?(:tokens)
        usage = Phronomy::LLMAdapter::TokenUsage.new(
          input: tokens&.input, output: tokens&.output,
          cached: tokens&.cache_read, cache_creation: tokens&.cache_write
        )
        metadata = {}
        metadata["model_id"] = message.model if message.respond_to?(:model) && message.model
        Response.new(content: message.content, tool_calls: calls, usage: usage, metadata: metadata)
      rescue ArgumentError, TypeError, NoMethodError => error
        raise InvalidResultError, "malformed provider response: #{error.message}"
      end

      def stream_value(chunk)
        raise InvalidResultError, "provider returned an invalid stream chunk" unless chunk.respond_to?(:content)
        StreamChunk.new(content: chunk.content)
      rescue ArgumentError => error
        raise InvalidResultError, "malformed provider chunk: #{error.message}"
      end

      # Translate SDK errors only. Cancellation and callback failures retain
      # identity; raising here preserves the original provider exception cause.
      def raise_provider_error(error)
        case error
        when ::RubyLLM::RateLimitError
          raise Phronomy::LLMAdapter::RateLimitError, error.message
        when ::RubyLLM::UnauthorizedError, ::RubyLLM::ForbiddenError
          raise Phronomy::LLMAdapter::AuthenticationError, error.message
        when ::RubyLLM::ContextLengthExceededError
          raise Phronomy::LLMAdapter::ContextLengthError, error.message
        when ::RubyLLM::Error
          raise Phronomy::LLMAdapter::TransportError, error.message
        else
          raise error
        end
      end
    end
  end
end
