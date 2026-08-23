# frozen_string_literal: true

module Phronomy
  module Agent
    class AgentInvocation
      # execution_id is the logical Agent execution parent. Concrete Runtime
      # routing identity belongs only to the owning FSMSession incarnation.
      TOOL_EVENT_TYPES = %i[
        tool_authorized
        tool_approval_required
        tool_completed
        tool_failed
        tool_rejected
        tool_cancelled
      ].freeze

      LLM_EVENT_TYPES = %i[llm_completed llm_failed].freeze
      CALLBACK_FAILED_EVENTS = %i[application_callback_failed].freeze

      attr_accessor :input,
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

      attr_reader :execution_id,
        :agent,
        :config,
        :approval_policy,
        :approval_listener,
        :pending_tool_calls,
        :tool_invocations,
        :phase,
        :mode,
        :current_llm_call_id,
        :tool_batch_llm_call_id,
        :handoff_request

      def initialize(
        agent:,
        input:,
        config:,
        approval_policy: nil,
        approval_listener: nil,
        event_listener: nil,
        mode: nil,
        execution_id: nil
      )
        @agent = agent
        @input = input
        @config = config
        resolved_execution_id = execution_id || config[:execution_id]
        @execution_id = resolved_execution_id&.to_s&.freeze
        invocation_context = config[:invocation_context]
        invocation_policy = if invocation_context&.respond_to?(:approval_policy)
          invocation_context.approval_policy
        end
        @approval_policy = invocation_policy || approval_policy
        @approval_listener = approval_listener
        @event_listener = event_listener
        @mode = (mode || :invoke).to_sym

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
        @phase = nil
        @current_llm_call_id = nil
        @tool_batch_llm_call_id = nil
        @handoff_request = nil
      end

      def streaming?
        @mode == :stream
      end

      def set_graph_metadata(phase: nil)
        @phase = phase
      end

      def begin_llm_call!(llm_call_id)
        @current_llm_call_id = llm_call_id.to_s
        self
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
        @tool_batch_llm_call_id = nil
      end

      def handle_fsm_event(event)
        if event.type == :llm_stream_chunk
          deliver_event(StreamEvent.new(type: :token, payload: {content: event.payload.fetch(:content)}))
          return true
        end

        if LLM_EVENT_TYPES.include?(event.type)
          apply_llm_event(event)
          return true
        end

        if CALLBACK_FAILED_EVENTS.include?(event.type)
          @error ||= event.payload.fetch(:failure).to_stream_callback_error
          return true
        end

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

      def accept_tool_calls!(tool_calls, llm_call_id: nil)
        @user_message_sent = true
        calls = Array(tool_calls)
        call_llm_id = (llm_call_id || @current_llm_call_id)&.to_s
        handoff_matches = handoff_matches_for(calls)

        unless handoff_matches.empty?
          if handoff_matches.length != 1 || calls.length != 1
            @error = Phronomy::HandoffError.new(
              "one Provider outcome cannot mix Handoff with ordinary Tool Calls or multiple Handoffs"
            )
            @pending_tool_calls = []
            @tool_batch_llm_call_id = call_llm_id
            @current_llm_call_id = nil
            return self
          end

          tool_call, binding = handoff_matches.first
          @handoff_request = build_handoff_request(
            tool_call,
            binding,
            llm_call_id: call_llm_id
          )
          @pending_tool_calls = []
          @tool_batch_llm_call_id = call_llm_id
          @current_llm_call_id = nil
          return self
        end

        @pending_tool_calls = calls
        @tool_batch_llm_call_id = call_llm_id
        @current_llm_call_id = nil
        @pending_tool_calls.each do |tool_call|
          deliver_event(
            StreamEvent.new(
              type: :tool_call,
              payload: {
                tool_call: tool_call,
                llm_call_id: @tool_batch_llm_call_id
              }.compact
            )
          )
        end
        self
      rescue => caught
        @error = caught.is_a?(Phronomy::HandoffError) ? caught :
          Phronomy::HandoffError.new("invalid Handoff request: #{caught.message}")
        @pending_tool_calls = []
        @current_llm_call_id = nil
        self
      end

      def handoff_requested?
        !@handoff_request.nil?
      end

      def handoff_failed?
        @error.is_a?(Phronomy::HandoffError) && !handoff_requested?
      end

      def apply_llm_response!(response)
        raise Phronomy::Error, "LLM operation completed without a response" unless response

        @user_message_sent = true
        @output = response.content
        @usage = Phronomy::TokenUsage.from_tokens(response.tokens)
        @pending_tool_calls = []
        @current_llm_call_id = nil
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

        %i[user_id token_budget task_id parent_task_id].each_with_object({}) do |name, result|
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
          tool_content = invocation.result.to_s
          @chat.add_message(
            role: :tool,
            content: tool_content,
            tool_call_id: invocation.tool_call_id
          )
          deliver_event(
            StreamEvent.new(
              type: :tool_result,
              payload: {
                tool_call_id: invocation.tool_call_id,
                tool_name: invocation.tool_name,
                tool_result: invocation.result,
                tool_message: {
                  "role" => "tool",
                  "content" => tool_content,
                  "tool_call_id" => invocation.tool_call_id.to_s
                },
                llm_call_id: @tool_batch_llm_call_id
              }.compact
            )
          )
        end
        clear_tool_batch!
        self
      end

      def input_passed? = !@input_blocked
      def input_blocked? = @input_blocked
      def output_passed? = !@output_blocked
      def output_blocked? = @output_blocked
      def tool_call_pending? = !@pending_tool_calls.empty?

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
        preflight_failure = preflight_complete? && @tool_invocations.any? do |invocation|
          invocation.failed? || invocation.cancelled?
        end
        terminal_failure = tool_batch_terminal? && @tool_invocations.any? do |invocation|
          invocation.failed? || invocation.cancelled?
        end
        no_rejection && (preflight_failure || terminal_failure)
      end

      def tool_batch_rejected?
        return false unless @tool_invocations.any?(&:rejected?)

        @human_rejection ? tool_batch_terminal? : preflight_complete?
      end

      def tool_batch_completed?
        tool_batch_terminal? && @tool_invocations.all?(&:execution_completed?)
      end

      private

      def handoff_matches_for(calls)
        bindings = Array(@config[:phronomy_handoff_bindings])
        return [] if bindings.empty?

        by_name = bindings.to_h { |binding| [binding.tool_name.to_s, binding] }
        calls.filter_map do |tool_call|
          binding = by_name[tool_call.name.to_s]
          binding && [tool_call, binding]
        end
      end

      def build_handoff_request(tool_call, binding, llm_call_id:)
        handoff = binding.handoff
        unless handoff.source_agent.equal?(@agent)
          raise Phronomy::HandoffError,
            "Handoff capability is not bound to the active Source Agent"
        end

        args = tool_call.respond_to?(:arguments) ? tool_call.arguments : {}
        args = (args || {}).to_h.transform_keys(&:to_sym)
        selection = handoff.policy.selectable_categories.each_with_object({}) do |category, result|
          key = :"include_#{category}"
          result[category] = args[key] if args.key?(key)
        end
        Phronomy::MultiAgent::HandoffRequest.new(
          handoff: handoff,
          responsibility: args.fetch(:responsibility),
          selection_intent: selection,
          llm_call_id: llm_call_id,
          tool_call_id: tool_call.respond_to?(:id) ? tool_call.id : nil
        )
      end

      def apply_llm_event(event)
        result = event.payload
        unless result.is_a?(LLMOperationResult)
          raise Phronomy::Error, "Expected LLMOperationResult, got #{result.class}"
        end

        activation = @config[:phronomy_activation]
        if activation && @current_llm_call_id
          activation.record_llm_result(
            response: canonical_response_for_llm_result(result),
            error: result.error,
            streaming: result.streaming
          )
        end

        if event.type == :llm_failed
          @current_llm_call_id = nil
          @error = result.error || Phronomy::Error.new("LLM operation failed without an error")
          return
        end

        if result.error
          if result.error.is_a?(ToolCallIntercepted)
            accept_tool_calls!(
              result.error.tool_calls,
              llm_call_id: result.error.llm_call_id
            )
          else
            @current_llm_call_id = nil
            @error = result.error
          end
        else
          apply_llm_response!(result.response)
        end
      end

      def canonical_response_for_llm_result(result)
        if result.error.is_a?(ToolCallIntercepted)
          result.error.assistant_outcome || ProviderCallOutcome.capture(result.response)
        else
          ProviderCallOutcome.capture(result.response)
        end
      end

      def deliver_event(event)
        @event_listener&.call(event)
      end
    end
  end
end
