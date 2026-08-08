# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable, Phronomy-owned snapshot of one completed Provider assistant output.
    # It is captured before Agent-owned Tool execution begins, so durable logging
    # never depends on RubyLLM's later control flow or Application callbacks.
    ProviderCallOutcome = Data.define(:role, :content, :tool_calls, :usage, :metadata) do
      def self.capture(message)
        return if message.nil?

        calls = if message.respond_to?(:tool_calls) && message.tool_calls
          source = message.tool_calls.respond_to?(:values) ? message.tool_calls.values : Array(message.tool_calls)
          source.map { |call| normalize(tool_call_hash(call)) }
        else
          []
        end
        usage = if message.respond_to?(:tokens) && message.tokens
          normalize(message.tokens.respond_to?(:to_h) ? message.tokens.to_h : message.tokens)
        else
          {}
        end
        metadata = {}
        metadata["model_id"] = message.model_id.to_s if message.respond_to?(:model_id) && message.model_id

        new(
          role: message.respond_to?(:role) ? message.role : :assistant,
          content: normalize(message.respond_to?(:content) ? message.content : nil),
          tool_calls: calls,
          usage: usage,
          metadata: metadata
        )
      end

      def self.tool_call_hash(call)
        return call.to_h if call.respond_to?(:to_h)

        {
          "id" => call.respond_to?(:id) ? call.id : nil,
          "name" => call.respond_to?(:name) ? call.name : nil,
          "arguments" => call.respond_to?(:arguments) ? call.arguments : {}
        }.compact
      end
      private_class_method :tool_call_hash

      def self.normalize(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, normalize(child)] }
        when Array
          value.map { |child| normalize(child) }
        when Symbol
          value.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          if value.respond_to?(:to_h)
            normalize(value.to_h)
          else
            value.to_s
          end
        end
      end
      private_class_method :normalize

      def initialize(role:, content:, tool_calls:, usage: {}, metadata: {})
        super(
          role: role&.to_sym,
          content: Immutable.copy(content),
          tool_calls: Immutable.copy(Array(tool_calls)),
          usage: Immutable.copy(usage || {}),
          metadata: Immutable.copy(metadata || {})
        )
        Immutable.validate_canonical_json!(content, label: "Provider assistant content")
        Immutable.validate_canonical_json!(tool_calls, label: "Provider Tool Calls")
        Immutable.validate_canonical_json!(usage, label: "Provider usage")
        Immutable.validate_canonical_json!(metadata, label: "Provider outcome metadata")
        freeze
      end

      def content_present?
        !content.nil? && !(content.respond_to?(:empty?) && content.empty?)
      end

      def tool_call?
        !tool_calls.empty?
      end
    end
  end
end
