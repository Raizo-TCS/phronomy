# frozen_string_literal: true

module Phronomy
  module Agent
    # Raised internally inside the on_tool_call hook when an approval-required
    # tool is encountered and no synchronous on_approval_required handler has
    # been registered.  Caught by Agent::Base#invoke_once to produce a
    # suspended result hash containing a Checkpoint.
    #
    # This class is intentionally NOT part of the public API.  Callers should
    # @api private
    # inspect the +:suspended+ key in the result hash returned by #invoke.
    #
    # @api private
    class SuspendSignal < StandardError
      # @return [String] the name of the tool that triggered the suspension
      attr_reader :tool_name

      # @return [Hash] the arguments the LLM passed to the tool
      attr_reader :args

      # @return [String] the tool_call_id from the LLM response
      attr_reader :tool_call_id

      # @param tool_name    [String]
      # @param args         [Hash]
      # @param tool_call_id [String]
      # @api private
      def initialize(tool_name:, args:, tool_call_id:)
        super("Agent suspended waiting for approval of tool: #{tool_name}")
        @tool_name = tool_name
        @args = args
        @tool_call_id = tool_call_id
      end
    end
  end
end
