# frozen_string_literal: true

require_relative "message"
require_relative "token_usage"

module Phronomy
  module LLMAdapter
    # Completed assistant turn. Tool requests do not authorize execution.
    # @api public
    class Response < Message
      attr_reader :usage, :finish_reason, :refusal

      # @api public
      def initialize(content: nil, tool_calls: [], usage: Phronomy::LLMAdapter::TokenUsage.new, metadata: {}, role: :assistant,
        finish_reason: :unknown, refusal: nil)
        raise ArgumentError, "LLM response must be an assistant message" unless role == :assistant || role == "assistant"
        raise ArgumentError, "LLM usage must be LLMAdapter::TokenUsage" unless usage.is_a?(Phronomy::LLMAdapter::TokenUsage)
        @usage = usage
        unless %w[stop tool_calls length content_filter refusal unknown].include?(finish_reason.to_s)
          raise ArgumentError, "invalid LLM finish reason"
        end
        raise ArgumentError, "refusal must be a String or nil" unless refusal.nil? || refusal.is_a?(String)
        @finish_reason = finish_reason.to_sym
        @refusal = refusal&.dup&.freeze
        super(role: :assistant, content: content, tool_calls: tool_calls, metadata: metadata)
      end

      # @api public
      def self.from_h(value)
        source = value.transform_keys(&:to_s)
        new(role: source.fetch("role", "assistant"), content: source["content"],
          tool_calls: source.fetch("tool_calls", []).map { |call| Phronomy::Tool::CallRequest.from_h(call) },
          usage: Phronomy::LLMAdapter::TokenUsage.new(**source.fetch("usage", {}).transform_keys(&:to_sym)),
          metadata: source.fetch("metadata", {}), finish_reason: source.fetch("finish_reason", "unknown"), refusal: source["refusal"])
      end

      # @api public
      def to_h
        super.merge("usage" => usage.to_h.transform_keys(&:to_s), "finish_reason" => finish_reason.to_s, "refusal" => refusal)
      end
    end
  end
end
