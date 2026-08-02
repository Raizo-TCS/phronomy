# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Mutable domain state for one Agent invocation.
    #
    # AgentInvocation interprets Agent-internal events. FSMSession owns the
    # transition mechanics, while Agent::Base projects the terminal outcome to
    # both the Application listener and the returned Task.
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

      LLM_EVENT_TYPES = %i[
        llm_completed
        llm_failed
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
        :event_listener,
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
        :phase,
        :mode

      def initialize(
        agent:,
        input:,
        messages:,
        config:,
        approval_policy: nil,
        approval_listener: nil,
        event_listener: nil,
        stream_listener: nil,
        mode: nil,
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
        @event_listener = event_listener || stream_listener
        @mode = (mode || (stream_listener ? :stream : :invoke)).to_sym

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

      # Compatibility aliases for existing internal callers.
      def stream_listener
        @event_listener
      end

      def stream_listener=(listener)
        @event_listener = listener
      end

      def streaming?
        @mode == :stream
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

      def handle_fsm_event(event)
        if event.type == :llm_stream_chunk
          deliver_event(
            StreamEvent.new(
              type: :token,
              payload: {content: event.payload.fetch(:content)}
            )
          )
          return true
        end

        if LLM_EVENT_TYPES.include?(event.type)
          apply_llm_event(event)
          return true
        end

        return false unless TOOL_EVENT_TYPES.include?(event.type)

        invocation = tool_invocation(
          event.payload&.fetch(:tool_invocation_id, nil)
        )
        return true unless invocation

        @error ||= invocation.error if invocation.failed? || invocation.cancelled?
        @rejected = true if invocation.rejected?
        if @approval_resume_in_progress &&
            @pending_approval_resolution_ids.delete(invocation.id)
          if @pending_approval_resolution_ids.empty?
            @approval_resume_in_progress = false
          end
        end
        true
      end

      # Deprecated internal compatibility hook. FSMSession no longer calls
      # this method; asynchronous results enter through explicit events.
      def apply_fsm_action_result(result)
        event_type =
          if result.respond_to?(:error) &&
              result.error &&
              !result.error.is_a?(ToolCallIntercepted)
            :llm_failed
          else
            :llm_completed
          end
        handle_fsm_event(
          Phronomy::Event.new(
            type: event_type,
            target_id: @id,
            payload: result
          )
        )
        self
      end

      def accept_tool_calls!(tool_calls)
        @user_message_sent = true
        @pending_tool_calls = Array(tool_calls)
        @messages = @chat.messages
        @pending_tool_calls.each do |tool_call|
          deliver_event(
            StreamEvent.new(
              type: :tool_call,
              payload: {tool_call: tool_call}
            )
          )
        end
        self
      end

      def apply_llm_response!(response)
        unless response
          raise Phronomy::Error, "LLM operation completed without a response"
        end

        @user_message_sent = true
        @output = response.content
        @usage = Phronomy::TokenUsage.from_tokens(response.tokens)
        @messages = @chat.messages
        @pending_tool_calls = []
        self
      end

      def tool_invocation(id)
        @tool_invocations.find { |invocation| invocation.id == id.to_s }
      end

      def merge_config!(values)
        @config.merge!(values) unless values.empty?
        self
      end

      def approval_context
        return @config[:approval_context] if @config[:approval_context]

        context = @config[:invocation_context]
        return {} unless context

        %i[
          thread_id session_id user_id token_budget
          task_id parent_task_id
        ].each_with_object({}) do |name, result|
          if context.respond_to?(name)
            result[name] = context.public_send(name)
          end
        end
      end

      def begin_approval_resume!(approved:)
        @human_rejection = !approved
        @pending_approval_resolution_ids = @tool_invocations
          .select(&:awaiting_approval?)
          .map(&:id)
        @approval_resume_in_progress =
          !@pending_approval_resolution_ids.empty?
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
          deliver_event(
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
        !@tool_invocations.empty? &&
          @tool_invocations.all?(&:preflight_settled?)
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
        !@tool_invocations.empty? &&
          @tool_invocations.all?(&:terminal?)
      end

      def tool_batch_failed?
        return false if @human_rejection || @approval_resume_in_progress

        no_rejection = @tool_invocations.none?(&:rejected?)
        preflight_failure =
          preflight_complete? &&
          @tool_invocations.any? do |invocation|
            invocation.failed? || invocation.cancelled?
          end
        terminal_failure =
          tool_batch_terminal? &&
          @tool_invocations.any? do |invocation|
            invocation.failed? || invocation.cancelled?
          end
        no_rejection && (preflight_failure || terminal_failure)
      end

      def tool_batch_rejected?
        return false unless @tool_invocations.any?(&:rejected?)

        @human_rejection ? tool_batch_terminal? : preflight_complete?
      end

      def tool_batch_completed?
        tool_batch_terminal? &&
          @tool_invocations.all?(&:execution_completed?)
      end

      private

      def apply_llm_event(event)
        result = event.payload
        unless result.is_a?(LLMOperationResult)
          raise Phronomy::Error,
            "Expected LLMOperationResult, got #{result.class}"
        end

        if event.type == :llm_failed
          @error = result.error ||
            Phronomy::Error.new("LLM operation failed without an error")
          return
        end

        if result.error
          if result.error.is_a?(ToolCallIntercepted)
            accept_tool_calls!(result.error.tool_calls)
          else
            @error = result.error
          end
        else
          apply_llm_response!(result.response)
        end
      end

      def deliver_event(event)
        @event_listener&.call(event)
      end
    end
  end
end
