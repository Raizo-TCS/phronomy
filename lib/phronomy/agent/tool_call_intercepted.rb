# frozen_string_literal: true

module Phronomy
  module Agent
    # Raised inside the on_tool_call hook registered by InvocationSession
    # to intercept every tool call before RubyLLM executes it.
    #
    # Catching this exception in calling_llm_action lets the Agent FSM
    # route through :executing_tool (and possibly :awaiting_approval) rather
    # than executing the tool inside RubyLLM's internal loop.
    #
    # This class is intentionally NOT part of the public API.
    # @api private
    class ToolCallIntercepted < StandardError
      # @return [Object] the RubyLLM tool_call object (responds to #name, #arguments, #id)
      attr_reader :tool_call

      # @param tool_call [Object] the RubyLLM tool_call object
      # @api private
      def initialize(tool_call)
        super("Tool call intercepted: #{tool_call.name}")
        @tool_call = tool_call
      end
    end
  end
end
