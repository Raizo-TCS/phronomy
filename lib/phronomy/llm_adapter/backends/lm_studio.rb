# frozen_string_literal: true

require_relative "ruby_llm"

module Phronomy
  module LLMAdapter
    # Explicit LM Studio / RubyLLM connection. Does not alter the default backend.
    # Identifies a narrowly specified provider response, not exception messages.
    # @api public
    class LMStudio < RubyLLM
      PARSE_FAILURE_CODE = "llm.provider_output_parse_failed"
      ENGINE_PREFIX = "Engine protocol predict stream returned an error: "
      ENGINE_MESSAGE = "The model produced output that does not match the expected peg-native format"
      private_constant :ENGINE_PREFIX, :ENGINE_MESSAGE

      # SDK retries are disabled in a private configuration snapshot. This also
      # disables ordinary 429/500 retries for this selected backend; the generic
      # RubyLLM backend is unchanged. Retries below are opt-in and bounded to one.
      # on_attempt receives safe diagnostic fields, never a prompt or raw body.
      # @api public
      def initialize(context:, max_parse_retries: 0, on_attempt: nil)
        raise ArgumentError, "context must be a RubyLLM::Context" unless context.is_a?(::RubyLLM::Context)
        unless max_parse_retries.is_a?(Integer) && (0..1).cover?(max_parse_retries)
          raise ArgumentError, "max_parse_retries must be 0 or 1"
        end
        raise ArgumentError, "on_attempt must be callable" if on_attempt && !on_attempt.respond_to?(:call)

        config = context.config.dup
        unless config.openai_protocol == :chat_completions
          raise ArgumentError, "LMStudio requires the Chat Completions protocol"
        end
        config.max_retries = 0
        super(context: ::RubyLLM::Context.new(config.freeze))
        @max_parse_retries = max_parse_retries
        @on_attempt = on_attempt
      end

      protected

      def perform_complete(request, cancellation_token:)
        require_openai!(request)
        attempt = 0
        begin
          cancellation_token&.raise_if_cancelled!
          attempt += 1
          response = super
        rescue TransportError => error
          retrying = error.code == PARSE_FAILURE_CODE && retryable_request?(request) &&
            attempt <= @max_parse_retries
          record_attempt(attempt, error: error, retrying: retrying)
          raise unless retrying

          retry
        end
        record_attempt(attempt)
        response
      end

      def perform_stream(request, cancellation_token:, &block)
        require_openai!(request)
        response = super
        record_attempt(1)
        response
      rescue TransportError => error
        record_attempt(1, error: error)
        raise
      end

      private

      def require_openai!(request)
        unless request.model_config["provider"] == "openai"
          raise ArgumentError, "LMStudio requires provider: openai"
        end
      end

      def retryable_request?(request)
        request.model_config["model"] == "openai/gpt-oss-20b" &&
          request.tools.empty? && request.response_schema.nil? &&
          request.messages.none? { |message| message.role == :tool || !message.tool_calls.empty? }
      end

      def raise_provider_error(error)
        if provider_parse_failure?(error)
          raise TransportError.new(error.message, code: PARSE_FAILURE_CODE), cause: error
        end
        super
      end

      def provider_parse_failure?(error)
        return false unless error.is_a?(::RubyLLM::BadRequestError) || error.is_a?(::RubyLLM::ServerError)

        response = error.response
        return false unless response && [400, 500].include?(response.status)

        body = response.body
        body = JSON.parse(body) if body.is_a?(String)
        return false unless body.is_a?(Hash)

        detail = body["error"]
        # Known engine fields can appear directly or inside LM Studio's exact
        # wrapper. These HTTP envelopes are synthetic test fixtures until a live
        # failure is captured; unknown envelopes deliberately remain unclassified.
        if detail.is_a?(Hash) && detail["message"].is_a?(String) && detail["message"].start_with?(ENGINE_PREFIX)
          detail = detail["message"]
        end
        if detail.is_a?(String) && detail.start_with?(ENGINE_PREFIX)
          detail = JSON.parse(detail.delete_prefix(ENGINE_PREFIX))
        end
        detail.is_a?(Hash) && detail["code"] == 500 &&
          detail["type"] == "server_error" && detail["message"] == ENGINE_MESSAGE
      rescue JSON::ParserError
        false
      end

      def record_attempt(attempt, error: nil, retrying: false)
        provider = error&.cause
        status = provider.response&.status if provider.is_a?(::RubyLLM::Error)
        event = {attempt: attempt, outcome: error ? :failed : :succeeded,
                 code: error&.code, http_status: status, retrying: retrying}.freeze
        warn_attempt(event) if error
        @on_attempt&.call(event)
      rescue
        # Diagnostics never replace the operation result or its original cause.
        nil
      end

      def warn_attempt(event)
        warning = "[Phronomy::LLMAdapter::LMStudio] attempt=#{event[:attempt]} " \
          "code=#{event[:code] || "transport_error"} http_status=#{event[:http_status] || "unknown"} retrying=#{event[:retrying]}"
        logger = @sdk_context.config.logger
        logger ? logger.warn(warning) : Kernel.warn(warning)
      rescue
        # A broken logger does not prevent the optional observer from running.
        nil
      end
    end
  end
end
