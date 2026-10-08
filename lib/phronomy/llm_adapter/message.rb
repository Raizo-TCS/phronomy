# frozen_string_literal: true

require_relative "../common/values/immutable"
require_relative "../tool/schema"
require_relative "../tool/call_request"

module Phronomy
  module LLMAdapter
    # Provider-independent conversation value, with no executable capabilities.
    # @api public
    class Message
      attr_reader :role, :content, :tool_calls, :tool_call_id, :metadata

      # @api public
      def initialize(role:, content: nil, tool_calls: [], tool_call_id: nil, metadata: {})
        unless role.respond_to?(:to_sym) && %i[system user assistant tool].include?(role.to_sym)
          raise ArgumentError, "invalid LLM message role"
        end
        unless content.nil? || content.is_a?(String) || content.is_a?(Array) || content.is_a?(Hash)
          raise ArgumentError, "LLM content must be text, structured JSON or nil"
        end
        unless tool_calls.is_a?(Array) && tool_calls.all? { |call| call.is_a?(Phronomy::Tool::CallRequest) }
          raise ArgumentError, "LLM Tool calls must be Tool::CallRequest values"
        end
        ids = tool_calls.map(&:id)
        raise ArgumentError, "duplicate LLM Tool call id" unless ids.uniq == ids
        raise ArgumentError, "only assistant messages can request Tools" if !tool_calls.empty? && role.to_sym != :assistant
        if role.to_sym == :tool && (!tool_call_id.is_a?(String) || tool_call_id.empty?)
          raise ArgumentError, "Tool message requires tool_call_id"
        end
        unless tool_call_id.nil? || tool_call_id.is_a?(String)
          raise ArgumentError, "tool_call_id must be a String"
        end
        raise ArgumentError, "LLM metadata must be a Hash" unless metadata.is_a?(Hash)
        Phronomy::Values::Immutable.validate_canonical_json!(content, label: "LLM content")
        Phronomy::Values::Immutable.validate_canonical_json!(metadata, label: "LLM metadata")
        @role = role.to_sym
        @content = Phronomy::Values::Immutable.copy(content)
        @tool_calls = tool_calls.dup.freeze
        @tool_call_id = tool_call_id&.dup&.freeze
        @metadata = Phronomy::Values::Immutable.copy(metadata)
        freeze
      end

      # @api public
      def tool_call?
        !tool_calls.empty?
      end

      # @api public
      def content_present?
        !content.nil? && !content.empty?
      end

      # @api public
      def to_h
        {"role" => role.to_s, "content" => content, "tool_calls" => tool_calls.map(&:to_h),
         "tool_call_id" => tool_call_id, "metadata" => metadata}.compact
      end
    end
  end
end
