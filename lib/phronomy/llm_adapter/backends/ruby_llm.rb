# frozen_string_literal: true

require "ruby_llm"
require "faraday"
require "digest"

module Phronomy
  module LLMAdapter
    # SDK objects are operation-local. Only Phronomy request/result values cross
    # the backend boundary; a Tool definition never contains executable work.
    # @api public
    class RubyLLM < Base
      # An optional RubyLLM context keeps endpoint/transport settings local to
      # this concrete backend. The default still reads the SDK global settings.
      # @api public
      def initialize(context: nil)
        @sdk_context = context || ::RubyLLM
      end

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
        capture = StructuredResponseCapture.new
        capture.bind(chat) if request.response_schema && block_given?
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
        response_value(response, capture: capture, chat: chat)
      rescue ToolsRequested => requested
        response_value(requested.message_value, capture: capture, chat: chat)
      rescue => error
        raise error if error.equal?(callback_error)
        if request.response_schema && unsupported_schema_error?(error)
          raise StructuredOutputUnsupportedError, "Provider rejected native structured output"
        end
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
        chat = @sdk_context.chat(**options)
        if request.response_schema
          validate_structured_support!(request, chat)
          chat.with_schema(request.response_schema)
        end
        chat.with_temperature(config["temperature"]) if config["temperature"]
        chat.with_max_output_tokens(config["max_output_tokens"]) if config["max_output_tokens"]
        if request.system
          chat.with_instructions(request.system, cache_until_here: config["cache_instructions"])
        end
        request.tools.each { |definition| chat.with_tools(tool_declaration(definition)) }
        request.messages.each { |value| chat.messages << sdk_message(value, chat: chat) }
        chat
      end

      def validate_structured_support!(request, chat)
        provider = chat.model.provider.to_s
        unless %w[openai azure anthropic gemini ollama].include?(provider)
          raise StructuredOutputUnsupportedError, "Native schema transport has not been verified for #{provider}"
        end
        begin
          known = ::RubyLLM.models.find(chat.model.id, provider: provider)
        rescue ::RubyLLM::ModelNotFoundError
          known = nil
        end
        if known && !known.supports?(:structured_output)
          raise StructuredOutputUnsupportedError, "Selected model does not support structured output"
        end
        if known && !request.tools.empty? && !known.supports?(:function_calling)
          raise StructuredOutputUnsupportedError, "Selected model cannot combine the requested schema and Tools"
        end
      end

      def unsupported_schema_error?(error)
        return false unless error.is_a?(::RubyLLM::BadRequestError)
        response = error.response if error.respond_to?(:response)
        body = response.respond_to?(:body) ? response.body : response
        body = JSON.parse(body) if body.is_a?(String)
        detail = body.is_a?(Hash) ? body["error"] : nil
        return true if detail == "Cannot combine structured output constraints with lazy grammar"
        return false unless detail.is_a?(Hash)
        schema_field = /response_format|output_config\.format|responseJsonSchema|response_schema|text\.format/
        message = detail["message"].to_s
        detail["param"].to_s.match?(/response_format|schema|text\.format|output_config/) ||
          %w[unsupported_response_format unsupported_schema invalid_json_schema].include?(detail["code"]) ||
          (message.match?(schema_field) && message.match?(/unsupported|not supported|invalid|unknown/i))
      rescue JSON::ParserError
        false
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

      def sdk_message(value, chat:)
        calls = value.tool_calls.to_h do |call|
          [call.id, ::RubyLLM::ToolCall.new(id: call.id, name: call.name,
            arguments: call.arguments, thought_signature: call.metadata["thought_signature"])]
        end
        content = value.content
        content = JSON.generate(content) if content.is_a?(Hash) || content.is_a?(Array)
        content = "" if value.role == :assistant && content.nil? && !calls.empty?
        ::RubyLLM::Message.new(role: value.role, content: content,
          tool_calls: calls.empty? ? nil : calls, tool_call_id: value.tool_call_id,
          model: value.metadata["model_id"], **sdk_continuation(value, chat))
      end

      def response_value(message, chat:, capture: nil)
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
        continuation = continuation_metadata(message, chat)
        metadata["ruby_llm_continuation"] = continuation if continuation
        reason = message.finish_reason if message.respond_to?(:finish_reason)
        raw = message.raw if message.respond_to?(:raw)
        raw = raw.body if raw.respond_to?(:body)
        raw = {} unless raw.is_a?(Hash)
        raw_reason = capture&.raw_finish_reason || raw.dig("choices", 0, "finish_reason") || raw["stop_reason"] ||
          raw.dig("candidates", 0, "finishReason") || reason&.to_s
        refusal = capture&.refusal || raw.dig("choices", 0, "message", "refusal")
        if raw["output"].is_a?(Array)
          refusals = raw["output"].flat_map { |item| Array(item["content"]) }
            .select { |item| item["type"] == "refusal" }.map { |item| item["refusal"] }
          refusal ||= refusals.join("\n") unless refusals.empty?
        end
        refusal ||= message.content.to_s if raw_reason == "refusal"
        normalized = refusal ? :refusal : {stop: :stop, tool_calls: :tool_calls,
                                           max_tokens: :length, length: :length, content_filter: :content_filter, refusal: :refusal}.fetch(reason&.to_sym, :unknown)
        metadata["raw_finish_reason"] = raw_reason if raw_reason
        Response.new(content: message.content, tool_calls: calls, usage: usage, metadata: metadata,
          finish_reason: normalized, refusal: refusal)
      rescue ArgumentError, TypeError, NoMethodError => error
        raise InvalidResultError, "malformed provider response: #{error.message}"
      end

      # Only this concrete backend interprets the envelope. Agent persists and
      # materializes Message metadata as immutable JSON, without SDK knowledge.
      def continuation_metadata(message, chat)
        thinking = message.thinking if message.respond_to?(:thinking)
        raw = message.raw_reasoning if message.respond_to?(:raw_reasoning)
        return unless thinking || raw

        {
          "version" => 1,
          "scope" => continuation_scope(chat),
          "thinking" => thinking && {"text" => thinking.text, "signature" => thinking.signature}.compact,
          "raw_reasoning" => raw
        }.compact
      end

      def sdk_continuation(value, chat)
        return {} unless value.metadata.key?("ruby_llm_continuation")

        state = value.metadata["ruby_llm_continuation"]
        unless state.is_a?(Hash) && state["version"] == 1 && state["scope"] == continuation_scope(chat)
          raise Phronomy::ConfigurationError,
            "RubyLLM continuation metadata is incompatible with the selected model, provider, endpoint, protocol or format version"
        end
        thinking = state["thinking"]
        valid_thinking = thinking.nil? || (thinking.is_a?(Hash) && (thinking.keys - %w[text signature]).empty? &&
          (thinking["text"].nil? || thinking["text"].is_a?(String)))
        unless value.role == :assistant && valid_thinking &&
            (state.keys - %w[version scope thinking raw_reasoning]).empty?
          raise InvalidResultError, "malformed RubyLLM continuation metadata"
        end
        # Reconstitute SDK-owned values only at the backend boundary. Do not
        # promote arbitrary Message metadata to SDK options or provider params.
        {thinking: thinking, raw_reasoning: state["raw_reasoning"]}
      end

      def continuation_scope(chat)
        provider = chat.provider
        protocol = provider.protocols.key(provider.protocol_for(chat.model))
        unless protocol
          raise Phronomy::ConfigurationError, "RubyLLM continuation requires an identifiable protocol"
        end
        {
          "provider" => chat.model.provider.to_s,
          "model" => chat.model.id,
          "protocol" => protocol.to_s,
          "endpoint_sha256" => Digest::SHA256.hexdigest(provider.api_base.to_s)
        }
      end

      def stream_value(chunk)
        raise InvalidResultError, "provider returned an invalid stream chunk" unless chunk.respond_to?(:content)
        StreamChunk.new(content: chunk.content)
      rescue ArgumentError => error
        raise InvalidResultError, "malformed provider chunk: #{error.message}"
      end

      # Translate identified SDK/HTTP failures only. Callback failures bypass
      # this method even when their class is a transport error. Classification
      # preserves cause; it does not promise that replay would be safe.
      def raise_provider_error(error)
        case error
        when ::RubyLLM::RateLimitError
          raise Phronomy::LLMAdapter::RateLimitError, error.message
        when ::RubyLLM::UnauthorizedError, ::RubyLLM::ForbiddenError
          raise Phronomy::LLMAdapter::AuthenticationError, error.message
        when ::RubyLLM::ContextLengthExceededError
          raise Phronomy::LLMAdapter::ContextLengthError, error.message
        when ::RubyLLM::Error, ::Faraday::TimeoutError, ::Faraday::ConnectionFailed
          raise Phronomy::LLMAdapter::TransportError.new(error.message), cause: error
        else
          raise error
        end
      end
    end
  end
end
