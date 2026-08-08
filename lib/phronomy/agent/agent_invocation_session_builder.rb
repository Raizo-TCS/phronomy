# frozen_string_literal: true

module Phronomy
  module Agent
    # Builds FSMSession instances for AgentInvocation objects.
    #
    # Blocking/provider work returns through explicit Agent-internal events.
    # Entry actions start operations and return synchronously.
    #
    # @api private
    class AgentInvocationSessionBuilder
      AUTO_STATE_SET = {
        idle: true,
        filtering_input: true,
        building_context: true,
        starting_tools: true,
        evaluating_tools: true,
        dispatching_tools: true,
        recording_tool_results: true,
        output_filtering: true
      }.freeze

      DECLARED_STATES = %i[
        idle filtering_input building_context calling_llm starting_tools
        evaluating_tools waiting_for_tools dispatching_tools
        recording_tool_results suspended output_filtering completed blocked failed
      ].freeze

      WAIT_STATES = %i[suspended].freeze

      TOOL_EVENTS = %i[
        tool_authorized
        tool_approval_required
        tool_completed
        tool_failed
        tool_rejected
        tool_cancelled
      ].freeze

      def self.build(
        agent:,
        input:,
        messages:,
        config:,
        approval_policy: nil,
        approval_listener: nil,
        mode: :invoke,
        on_event: nil,
        runtime: Phronomy::Runtime.instance
      )
        invocation = AgentInvocation.new(
          agent: agent,
          input: input,
          messages: messages,
          config: config,
          approval_policy: approval_policy,
          approval_listener: approval_listener,
          event_listener: on_event,
          mode: mode
        )
        build_session(
          agent_invocation: invocation,
          runtime: runtime,
          mode: mode
        )
      end

      def self.build_for_resume(
        agent_invocation:,
        resume_event:,
        resume_phase:,
        runtime: Phronomy::Runtime.instance
      )
        build_session(
          agent_invocation: agent_invocation,
          runtime: runtime,
          mode: agent_invocation.mode,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end

      def self.build_session(
        agent_invocation:,
        runtime:,
        mode:,
        resume_event: nil,
        resume_phase: nil
      )
        agent = agent_invocation.agent
        actions = build_entry_actions(agent, runtime, mode: mode)
        phase_machine = Agent::PhaseMachineBuilder.new(
          entry_actions: actions
        ).build
        iterations = agent.class.max_iterations || 10

        Phronomy::FSMSession.new(
          id: agent_invocation.id,
          context: agent_invocation,
          entry_point: :idle,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: WAIT_STATES,
          external_events: external_events,
          recursion_limit: 12 + (iterations * 8),
          event_loop: runtime.event_loop,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end
      private_class_method :build_session

      def self.external_events
        tool_transitions = TOOL_EVENTS.to_h do |event_name|
          [
            event_name,
            [{from: :waiting_for_tools, to: :evaluating_tools, guard: nil}]
          ]
        end

        tool_transitions.merge(
          llm_completed: [
            {from: :calling_llm, to: :starting_tools, guard: ->(ctx) {
              ctx.tool_call_pending?
            }},
            {from: :calling_llm, to: :output_filtering, guard: nil}
          ],
          llm_failed: [
            {from: :calling_llm, to: :failed, guard: nil}
          ],
          resume: [
            {from: :suspended, to: :waiting_for_tools, guard: nil}
          ],
          application_callback_failed: [
            {from: :filtering_input, to: :failed, guard: nil},
            {from: :building_context, to: :failed, guard: nil},
            {from: :calling_llm, to: :failed, guard: nil},
            {from: :starting_tools, to: :failed, guard: nil},
            {from: :evaluating_tools, to: :failed, guard: nil},
            {from: :waiting_for_tools, to: :failed, guard: nil},
            {from: :dispatching_tools, to: :failed, guard: nil},
            {from: :recording_tool_results, to: :failed, guard: nil},
            {from: :output_filtering, to: :failed, guard: nil}
          ]
        )
      end
      private_class_method :external_events

      def self.build_entry_actions(agent, runtime, mode:)
        calling_action = if mode.to_sym == :stream
          method(:calling_llm_stream_action).curry.call(agent, runtime)
        else
          method(:calling_llm_action).curry.call(agent, runtime)
        end

        {
          filtering_input: [
            method(:filtering_input_action).curry.call(agent)
          ],
          building_context: [
            method(:building_context_action).curry.call(agent)
          ],
          calling_llm: [calling_action],
          starting_tools: [
            method(:starting_tools_action).curry.call(runtime)
          ],
          dispatching_tools: [
            method(:dispatching_tools_action).curry.call(runtime)
          ],
          recording_tool_results: [
            method(:recording_tool_results_action)
          ],
          suspended: [method(:suspended_action)],
          output_filtering: [
            method(:output_filtering_action).curry.call(agent)
          ],
          failed: [method(:failed_action)]
        }
      end
      private_class_method :build_entry_actions

      def self.filtering_input_action(agent, invocation)
        agent.send(
          :check_cancellation!,
          invocation.config,
          "invocation cancelled before input filtering"
        )
        invocation.input = agent.send(
          :run_input_filters!,
          invocation.input
        )
        invocation
      rescue Phronomy::FilterBlockError => error
        invocation.input_blocked = true
        invocation.block_error = error
        invocation
      end
      private_class_method :filtering_input_action

      def self.building_context_action(agent, invocation)
        invocation.chat = agent.send(:build_chat)
        context = agent.send(
          :build_context,
          invocation.input,
          messages: invocation.messages,
          thread_id: invocation.thread_id,
          config: invocation.config,
          budget: agent.send(:build_token_budget),
          instruction: agent.send(:build_instructions, invocation.input),
          tools: agent.class.tools + agent.send(:_handoff_tools)
        )
        agent.send(:_apply_context_to_chat, invocation.chat, context)
        agent.send(
          :run_before_completion_hooks!,
          invocation.chat,
          invocation.config
        )
        install_tool_interceptors(invocation.chat, invocation)
        invocation
      end
      private_class_method :building_context_action

      # RubyLLM >= 1.15 adds the complete assistant Message to chat.messages
      # before before_tool_call is fired. Capture that Message at the control
      # boundary instead of trying to recover it after the exception unwinds.
      def self.install_tool_interceptors(chat, invocation = nil)
        unless chat.respond_to?(:before_tool_call)
          raise Phronomy::ConfigurationError,
            "Agent-owned Tool execution requires RubyLLM >= 1.15 (before_tool_call callback)"
        end

        if chat.respond_to?(:on_tool_call_batch)
          chat.on_tool_call_batch do |tool_calls|
            raise build_tool_interception(chat, tool_calls, invocation)
          end
        end

        chat.before_tool_call do |tool_call|
          raise build_tool_interception(chat, [tool_call], invocation)
        end
      end
      private_class_method :install_tool_interceptors

      def self.build_tool_interception(chat, fallback_tool_calls, invocation)
        assistant_message = chat.messages.last
        unless assistant_message &&
            assistant_message.respond_to?(:role) &&
            assistant_message.role.to_sym == :assistant &&
            assistant_message.respond_to?(:tool_calls)
          raise Phronomy::Error,
            "RubyLLM Tool callback fired before the complete assistant message was observable"
        end

        message_tool_calls = assistant_message.tool_calls
        tool_calls = if message_tool_calls.respond_to?(:values)
          message_tool_calls.values
        else
          Array(message_tool_calls)
        end
        tool_calls = Array(fallback_tool_calls) if tool_calls.empty?

        ToolCallIntercepted.new(
          tool_calls,
          assistant_message: assistant_message,
          assistant_outcome: ProviderCallOutcome.capture(assistant_message),
          llm_call_id: invocation&.current_llm_call_id
        )
      end
      private_class_method :build_tool_interception

      def self.calling_llm_action(agent, runtime, invocation)
        user_message = invocation.user_message_sent ?
          nil :
          agent.send(:extract_message, invocation.input)
        agent.send(
          :check_cancellation!,
          invocation.config,
          "invocation cancelled before LLM call"
        )
        operation = Phronomy.configuration.llm_adapter.complete_async(
          invocation.chat,
          user_message,
          config: invocation.config
        )
        observe_llm_operation(
          operation,
          invocation,
          runtime: runtime,
          streaming: false
        )
        invocation
      end
      private_class_method :calling_llm_action

      def self.calling_llm_stream_action(agent, runtime, invocation)
        user_message = invocation.user_message_sent ?
          nil :
          agent.send(:extract_message, invocation.input)
        agent.send(
          :check_cancellation!,
          invocation.config,
          "invocation cancelled before LLM call"
        )

        operation = Phronomy.configuration.llm_adapter.stream_async(
          invocation.chat,
          user_message,
          config: invocation.config
        ) do |chunk|
          agent.send(
            :check_cancellation!,
            invocation.config,
            "invocation cancelled during streaming"
          )
          post_to_invocation!(
            runtime,
            invocation.id,
            :llm_stream_chunk,
            {content: chunk.content}
          )
        end

        observe_llm_operation(
          operation,
          invocation,
          runtime: runtime,
          streaming: true
        )
        invocation
      end
      private_class_method :calling_llm_stream_action

      def self.observe_llm_operation(
        operation,
        invocation,
        runtime:,
        streaming:
      )
        operation.on_complete do |response, error|
          result = LLMOperationResult.new(
            response: response,
            error: error,
            streaming: streaming
          )
          event_type =
            if error && !error.is_a?(ToolCallIntercepted)
              :llm_failed
            else
              :llm_completed
            end
          post_to_invocation!(
            runtime,
            invocation.id,
            event_type,
            result
          )
        end
      end
      private_class_method :observe_llm_operation

      def self.post_to_invocation!(
        runtime,
        invocation_id,
        event_type,
        payload
      )
        accepted = runtime.event_loop.post_to_session(
          Phronomy::Event.new(
            type: event_type,
            target_id: invocation_id,
            payload: payload
          )
        )
        return if accepted

        Phronomy.configuration.logger&.warn(
          "[Phronomy] Dropped late #{event_type.inspect} for " \
          "AgentInvocation #{invocation_id}"
        )
      end
      private_class_method :post_to_invocation!

      def self.starting_tools_action(runtime, invocation)
        children = invocation.pending_tool_calls.map do |tool_call|
          tool = invocation.chat.tools[tool_call.name.to_sym]
          if tool
            ToolInvocation.new(
              parent_agent_invocation_id: invocation.id,
              agent: invocation.agent,
              tool: tool,
              tool_call: tool_call,
              config: invocation.config,
              approval_policy: invocation.approval_policy,
              approval_context: invocation.approval_context
            )
          else
            ToolInvocation.missing(
              parent_agent_invocation_id: invocation.id,
              agent: invocation.agent,
              tool_call: tool_call,
              config: invocation.config
            )
          end
        end
        invocation.tool_invocations = children

        children.reject(&:terminal?).each do |child|
          session = ToolInvocationSessionBuilder.build(
            tool_invocation: child,
            runtime: runtime
          )
          register_child_session(runtime, child, session)
        end
        invocation
      end
      private_class_method :starting_tools_action

      def self.dispatching_tools_action(runtime, invocation)
        invocation.tool_invocations
          .select(&:authorized?)
          .each do |child|
            session = ToolInvocationSessionBuilder.build_for_resume(
              tool_invocation: child,
              resume_event: :dispatch,
              resume_phase: :authorized,
              runtime: runtime
            )
            register_child_session(runtime, child, session)
          end
        invocation
      end
      private_class_method :dispatching_tools_action

      def self.register_child_session(runtime, child, session)
        completion = Phronomy::Task.deferred(
          name: "tool-session:#{child.id}"
        )
        completion.on_complete do |_result, error|
          next unless error

          child.mark_framework_failed!(error)
          runtime.event_loop.post_to_session(
            Phronomy::Event.new(
              type: :tool_failed,
              target_id: child.parent_agent_invocation_id,
              payload: {tool_invocation_id: child.id}
            )
          )
        end
        runtime.event_loop.register(session, completion: completion)
      end
      private_class_method :register_child_session

      def self.recording_tool_results_action(invocation)
        invocation.record_tool_results!
      end
      private_class_method :recording_tool_results_action

      def self.suspended_action(invocation)
        invocation.prepare_approval_request!
      end
      private_class_method :suspended_action

      def self.failed_action(invocation)
        raise(
          invocation.error ||
          Phronomy::ToolError.new("Agent invocation failed")
        )
      end
      private_class_method :failed_action

      def self.output_filtering_action(agent, invocation)
        invocation.output = agent.send(
          :run_output_filters!,
          invocation.output
        )
        invocation
      rescue Phronomy::FilterBlockError => error
        invocation.output_blocked = true
        invocation.block_error = error
        invocation
      end
      private_class_method :output_filtering_action
    end
  end
end
