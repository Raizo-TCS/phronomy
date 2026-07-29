# frozen_string_literal: true

module Phronomy
  module Agent
    # Raised by the Agent-owned RubyLLM ToolCall interceptor before execution.
    # @api private
    class ToolCallIntercepted < StandardError
      attr_reader :tool_calls

      def initialize(tool_calls)
        @tool_calls = Array(tool_calls).freeze
        names = @tool_calls.map(&:name).join(", ")
        super("Tool call intercepted: #{names}")
      end

      # Convenience accessor for callers that only support one ToolCall.
      def tool_call
        @tool_calls.first
      end
    end
  end
end
