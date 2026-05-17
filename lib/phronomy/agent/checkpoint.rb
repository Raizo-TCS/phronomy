# frozen_string_literal: true

module Phronomy
  module Agent
    # Encapsulates the suspended state of an agent invocation.
    #
    # A Checkpoint is returned as the +:checkpoint+ key of the result hash when
    # an approval-required tool is encountered and no synchronous
    # on_approval_required handler has been registered.
    #
    # Pass the checkpoint to Agent::Base#resume to continue execution after
    # obtaining an approval decision from the user or an external system.
    #
    # @example Suspend and resume
    #   result = agent.invoke("Do task X")
    #   if result[:suspended]
    #     approved = prompt_user(result[:checkpoint].pending_tool_name)
    #     result   = agent.resume(result[:checkpoint], approved: approved)
    #   end
    #   puts result[:output]
    class Checkpoint
      # @return [String, nil] the thread_id from the invocation config
      attr_reader :thread_id

      # @return [Array<RubyLLM::Message>] conversation messages up to and including
      #   the assistant message that requested the pending tool call
      attr_reader :messages

      # @return [String] the name of the tool awaiting approval
      attr_reader :pending_tool_name

      # @return [Hash] the arguments the LLM passed to the pending tool
      attr_reader :pending_tool_args

      # @return [String] the tool_call_id from the LLM response (required to
      #   inject the tool result message on resume)
      attr_reader :pending_tool_call_id

      # @param thread_id           [String, nil]
      # @param messages            [Array<RubyLLM::Message>]
      # @param pending_tool_name   [String]
      # @param pending_tool_args   [Hash]
      # @param pending_tool_call_id [String]
      def initialize(thread_id:, messages:, pending_tool_name:, pending_tool_args:, pending_tool_call_id:)
        @thread_id = thread_id
        @messages = messages.dup.freeze
        @pending_tool_name = pending_tool_name
        @pending_tool_args = pending_tool_args
        @pending_tool_call_id = pending_tool_call_id
      end
    end
  end
end
