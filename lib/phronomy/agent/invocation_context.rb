# frozen_string_literal: true

module Phronomy
  module Agent
    # Holds the mutable state for a single Agent#invoke execution.
    #
    # An InvocationContext is created at the start of each invoke call and
    # passed through every FSM state as the context object. It plays the same
    # role as WorkflowContext does for Workflow executions.
    #
    # Fields:
    #   input             — the (possibly filter-transformed) user input
    #   messages          — conversation history (Array of RubyLLM::Message)
    #   chat              — the RubyLLM::Chat object built during :building_context
    #   output            — the final LLM text response
    #   usage             — Phronomy::TokenUsage after completion
    #   tool_call_pending — whether the last LLM response contained a tool call
    #   approval_required — whether the pending tool requires human approval
    #   input_blocked     — whether an input filter called block!
    #   output_blocked    — whether an output filter called block!
    #   block_error       — the FilterBlockError raised (for :blocked terminal)
    #
    # @api private
    class InvocationContext
      # @return [String, Hash] user input (may be transformed by input filters)
      attr_accessor :input

      # @return [Array] conversation history
      attr_accessor :messages

      # @return [Object, nil] RubyLLM::Chat instance
      attr_accessor :chat

      # @return [String, nil] final LLM output text
      attr_accessor :output

      # @return [Phronomy::TokenUsage, nil]
      attr_accessor :usage

      # @return [Boolean] true when calling_llm returned a tool call
      attr_accessor :tool_call_pending

      # @return [Boolean] true when the pending tool requires human approval
      attr_accessor :approval_required

      # @return [Boolean] true when an input filter called block!
      attr_accessor :input_blocked

      # @return [Boolean] true when an output filter called block!
      attr_accessor :output_blocked

      # @return [Phronomy::FilterBlockError, nil]
      attr_accessor :block_error

      # @return [Phronomy::Agent::Base] the agent instance driving this invocation
      attr_reader :agent

      # @return [Hash] the config hash passed to invoke
      attr_reader :config

      # @return [String, nil] thread_id from config
      attr_reader :thread_id

      # @param agent    [Phronomy::Agent::Base]
      # @param input    [String, Hash]
      # @param messages [Array]
      # @param config   [Hash]
      # @api private
      def initialize(agent:, input:, messages:, config:)
        @agent = agent
        @input = input
        @messages = Array(messages)
        @config = config
        @thread_id = config[:thread_id]
        @chat = nil
        @output = nil
        @usage = nil
        @tool_call_pending = false
        @approval_required = false
        @input_blocked = false
        @output_blocked = false
        @block_error = nil
      end

      # Guard helpers used by PhaseMachineBuilder transitions.

      # @return [Boolean]
      # @api private
      def input_passed?
        !@input_blocked
      end

      # @return [Boolean]
      # @api private
      def input_blocked?
        @input_blocked
      end

      # @return [Boolean]
      # @api private
      def output_passed?
        !@output_blocked
      end

      # @return [Boolean]
      # @api private
      def output_blocked?
        @output_blocked
      end

      # @return [Boolean]
      # @api private
      def tool_call_pending?
        @tool_call_pending
      end

      # @return [Boolean]
      # @api private
      def approval_required?
        @approval_required
      end
    end
  end
end
