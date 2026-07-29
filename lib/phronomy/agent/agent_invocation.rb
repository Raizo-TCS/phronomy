# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Mutable state for one Agent::Base invocation.
    #
    # AgentInvocation is the aggregate root for child ToolInvocation objects.
    # It does not drive transitions itself; Phronomy::FSMSession does that.
    #
    # @api private
    class AgentInvocation
      TOOL_EVENT_TYPES = %i[
        tool_authorized
        tool_approval_required
        tool_completed
        tool_failed
        tool_rejected
        tool_cancelled
      ].freeze

      attr_accessor :input,
        :messages,
        :chat,
        :output,
        :usage,
        :input_blocked,
        :output_blocked,
        :block_error,
        :user_message_sent,
        :stream_listener,
        :approval_request,
        :rejected,
        :error

      attr_reader :id,
        :agent,
        :config,
        :thread_id,
        :approval_policy,
        :approval_listener,
        :pending_tool_calls,
        :tool_invocations,
        :session_id,
        :phase

      def initialize(
        agent:,
        input:,
        messages:,
        config:,
        approval_policy: nil,
        approval_listener: nil,
        stream_listener: nil,
        id: nil
      )
        @agent = agent
        @input = input
        @messages = Array(messages)
        @config = config
        @thread_id = config[:thread_id]
        @id = (id || config[:agent_invocation_id] || SecureRandom.uuid).to_s
        invocation_context = config[:invocation_context]
        invocation_policy = if invocation_context&.respond_to?(:approval_policy)
          invocation_context.approval_policy
        end
        @approval_policy = invocation_policy || approval_policy
        @approval_listener = approval_listener
        @stream_listener = stream_listener

        @chat = nil
        @output = nil
        @usage = nil
        @input_blocked = false
        @output_blocked = false
        @block_error = nil
        @user_message_sent = false
        @pending_tool_calls = []
        @tool_invocations = []
        @approval_request = nil
        @rejected = false
        @human_rejection = false
        @approval_resume_in_progress = false
        @pending_approval_resolution_ids = []
        @error = nil
        @session_id = nil
        @phase = nil
      end

      def set_graph_metadata(thread_id: nil, phase: nil)
        @session_id = thread_id if thread_id
        @phase = phase
      end

      def pending_tool_calls=(calls)
        @pending_tool_calls = Array(calls)
      end

      def tool_invocations=(invocations)
        @tool_invocations = Array(invocations)
      end

      def clear_tool_batch!
        @pending_tool_calls = []
        @tool_invocations = []
        @approval_request = nil
      end

      # Consumes child ToolInvocation events. FSMSession calls this on the
      # EventLoop thread before attempting an optional parent FSM transition.
      def handle_fsm_event(event)
        return false unless TOOL_EVENT_TYPES.include?(event.type)

        invocation = tool_invocation(event.payload&.fetch(:tool_invocation_id, nil))
        return true unless invocation

        @error ||= invocation.error if invocation.failed? || invocation.cancelled?
        @rejected = true if invocation.rejected?
        if @approval_resume_in_progress &&
            @pending_approval_resolution_ids.delete(invocation.id)
          @approval_resume_in_progress = false if @pending_approval_resolution_ids.empty?
        end
        true
      end

      def tool_invocation(id)
        @tool_invocations.find { |invocation| invocation.id == id.to_s }
      end

      def merge_config!(values)
        @config.merge!(values) unless values.empty?
        self
      end

      def max_parallel_tools
        value = @config[:max_parallel_tools]
        context = @config[:invocation_context]
        value ||= context.max_parallel_tools if context&.respond_to?(:max_parallel_tools)
        [Integer(value || 10), 1].max
      rescue ArgumentError, TypeError
        10
      end

      def approval_context
        return @config[:approval_context] if @config[:approval_context]

        context = @config[:invocation_context]
        return {} unless context

        %i[
          thread_id session_id user_id token_budget max_parallel_tools
          task_id parent_task_id
        ].each_with_object({}) do |name, result|
          result[name] = context.public_send(name) if context.respond_to?(name)
        end
      end

      def begin_approval_resume!(approved:)
        @human_rejection = !approved
        @pending_approval_resolution_ids = @tool_invocations
          .select(&:awaiting_approval?)
          .map(&:id)
        @approval_resume_in_progress = !@pending_approval_resolution_ids.empty?
        self
      end

      def prepare_approval_request!
        @approval_request = ToolApprovalRequest.build(self)
        self
      end

      def record_tool_results!
        @tool_invocations.each do |invocation|
          @chat.add_message(
            role: :tool,
            content: invocation.result.to_s,
            tool_call_id: invocation.tool_call_id
          )
          @stream_listener&.call(
            StreamEvent.new(
              type: :tool_result,
              payload: {
                tool_call_id: invocation.tool_call_id,
                tool_name: invocation.tool_name,
                tool_result: invocation.result
              }
            )
          )
        end
        @messages = @chat.messages
        clear_tool_batch!
        self
      end

      # Guard helpers used by Agent::PhaseMachineBuilder.

      def input_passed?
        !@input_blocked
      end

      def input_blocked?
        @input_blocked
      end

      def output_passed?
        !@output_blocked
      end

      def output_blocked?
        @output_blocked
      end

      def tool_call_pending?
        !@pending_tool_calls.empty?
      end

      def preflight_complete?
        !@tool_invocations.empty? && @tool_invocations.all?(&:preflight_settled?)
      end

      def approval_required?
        !@human_rejection &&
          !@approval_resume_in_progress &&
          preflight_complete? &&
          @tool_invocations.any?(&:awaiting_approval?)
      end

      def ready_to_dispatch?
        !@approval_resume_in_progress &&
          preflight_complete? &&
          @tool_invocations.none?(&:awaiting_approval?) &&
          @tool_invocations.none?(&:rejected?) &&
          @tool_invocations.none?(&:failed?) &&
          @tool_invocations.none?(&:cancelled?) &&
          @tool_invocations.any?(&:authorized?)
      end

      def tool_batch_terminal?
        !@tool_invocations.empty? && @tool_invocations.all?(&:terminal?)
      end

      def tool_batch_failed?
        return false if @human_rejection || @approval_resume_in_progress

        no_rejection = @tool_invocations.none?(&:rejected?)
        preflight_failure = preflight_complete? && @tool_invocations.any? { |invocation|
          invocation.failed? || invocation.cancelled?
        }
        terminal_failure = tool_batch_terminal? && @tool_invocations.any? { |invocation|
          invocation.failed? || invocation.cancelled?
        }
        no_rejection && (preflight_failure || terminal_failure)
      end

      def tool_batch_rejected?
        return false unless @tool_invocations.any?(&:rejected?)

        @human_rejection ? tool_batch_terminal? : preflight_complete?
      end

      def tool_batch_completed?
        tool_batch_terminal? && @tool_invocations.all?(&:execution_completed?)
      end
    end
  end
end
