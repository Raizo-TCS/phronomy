# frozen_string_literal: true

module Phronomy
  module Agent
    # Normal control-transfer signal raised before RubyLLM executes a Tool Call.
    #
    # RubyLLM >= 1.15 guarantees that the complete assistant message has already
    # been added to Chat#messages before before_tool_call runs. Keeping that
    # message here allows Phronomy to persist the complete Provider outcome even
    # though the RubyLLM call itself unwinds through this exception.
    # @api private
    class ToolCallIntercepted < StandardError
      attr_reader :tool_calls, :assistant_message, :assistant_outcome, :llm_call_id

      def initialize(tool_calls, assistant_message: nil, assistant_outcome: nil, llm_call_id: nil)
        @tool_calls = Array(tool_calls).freeze
        @assistant_message = assistant_message
        @assistant_outcome = assistant_outcome || ProviderCallOutcome.capture(assistant_message)
        @llm_call_id = llm_call_id&.to_s&.freeze
        names = @tool_calls.map(&:name).join(", ")
        super("Tool call intercepted: #{names}")
      end

      def tool_call
        @tool_calls.first
      end
    end
  end
end
