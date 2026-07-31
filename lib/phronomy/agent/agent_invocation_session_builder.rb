# frozen_string_literal: true

module Phronomy
  module Agent
    # Builds Phronomy::FSMSession instances for AgentInvocation objects.
    #
    # This is a builder/factory, not the stateful invocation itself.
    # @api private
    class AgentInvocationSessionBuilder
      AUTO_STATE_SET = {
        idle: true,
        filtering_input: true,
        building_context: true,
        calling_llm: true,
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
          stream_listener: (mode == :stream) ? on_event : nil
        )
        build_session(agent_invocation: invocation, runtime: runtime, mode: mode)
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
          mode: agent_invocation.stream_listener ? :stream : :invoke,
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
        phase_machine = Agent::PhaseMachineBuilder.new(entry_actions: actions).build
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
          timer_queue_provider: -> { runtime.timer_queue },
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end
      private_class_method :build_session

      def self.external_events
        tool_transitions = TOOL_EVENTS.to_h do |event|
          [event, [{from: :waiting_for_tools, to: :evaluating_tools, guard: nil}]]
        end
        tool_transitions.merge(
          resume: [{from: :suspended, to: :waiting_for_tools, guard: nil}]
        )
      end
      private_class_method :external_events

      def self.build_entry_actions(agent, runtime, mode:)
        calling_action = if mode == :stream
          method(:calling_llm_stream_action).curry.call(agent, runtime)
        else
          method(:calling_llm_action).curry.call(agent)
        end

        {
          filtering_input: [method(:filtering_input_action).curry.call(agent)],
          building_context: [method(:building_context_action).curry.call(agent)],
          calling_llm: [calling_action],
          starting_tools: [method(:starting_tools_action).curry.call(runtime)],
          dispatching_tools: [method(:dispatching_tools_action).curry.call(runtime)],
          recording_tool_results: [method(:recording_tool_results_action)],
          suspended: [method(:suspended_action)],
          output_filtering: [method(:output_filtering_action).curry.call(agent)],
          failed: [method(:failed_action)]
        }
      end
      private_class_method :build_entry_actions

      def self.filtering_input_action(agent, invocation)
        invocation.input = agent.send(:run_input_filters!, invocation.input)
        invocation
      rescue Phronomy::FilterBlockError => e
        invocation.input_blocked = true
        invocation.block_error = e
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
        agent.send(:run_before_completion_hooks!, invocation.chat, invocation.config)
        install_tool_interceptors(invocation.chat)
        invocation
      end
      private_class_method :building_context_action

      def self.install_tool_interceptors(chat)
        if chat.respond_to?(:on_tool_call_batch)
          chat.on_tool_call_batch do |tool_calls|
            raise Phronomy::Agent::ToolCallIntercepted.new(tool_calls)
          end
        end
        chat.on_tool_call do |tool_call|
          raise Phronomy::Agent::ToolCallIntercepted.new(tool_call)
        end
      end
      private_class_method :install_tool_interceptors

      def self.calling_llm_action(agent, invocation)
        user_message = invocation.user_message_sent ? nil : agent.send(:extract_message, invocation.input)
        agent.send(:check_cancellation!, invocation.config, "invocation cancelled before LLM call")
        operation = Phronomy.configuration.llm_adapter.complete_async(
          invocation.chat,
          user_message,
          config: invocation.config
        )
        bridge_llm_operation(operation, invocation, streaming: false)
      end
      private_class_method :calling_llm_action

      def self.calling_llm_stream_action(agent, runtime, invocation)
        user_message = invocation.user_message_sent ? nil : agent.send(:extract_message, invocation.input)
        agent.send(:check_cancellation!, invocation.config, "invocation cancelled before LLM call")
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
          accepted = runtime.event_loop.post(
            Phronomy::Event.new(
              type: :llm_stream_chunk,
              target_id: invocation.id,
              payload: {content: chunk.content}
            )
          )
          unless accepted
            raise Phronomy::RuntimeShutdownError,
              "Runtime stopped while streaming AgentInvocation #{invocation.id}"
          end
        end
        bridge_llm_operation(operation, invocation, streaming: true)
      end
      private_class_method :calling_llm_stream_action

      def self.bridge_llm_operation(operation, invocation, streaming:)
        task = Phronomy::Task.deferred(
          name: "agent-llm#{"-stream" if streaming}:#{invocation.id}"
        )
        operation.on_complete do |response, error|
          complete_task(
            task,
            LLMOperationResult.new(
              response: response,
              error: error,
              streaming: streaming
            )
          )
        end
        task
      end
      private_class_method :bridge_llm_operation

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
        completion = Phronomy::Task.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          child.mark_framework_failed!(error)
          runtime.event_loop.post(
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
        raise(invocation.error || Phronomy::ToolError.new("ToolInvocation batch failed"))
      end
      private_class_method :failed_action

      def self.output_filtering_action(agent, invocation)
        invocation.output = agent.send(:run_output_filters!, invocation.output)
        invocation
      rescue Phronomy::FilterBlockError => e
        invocation.output_blocked = true
        invocation.block_error = e
        invocation
      end
      private_class_method :output_filtering_action

      def self.complete_task(task, value)
        task.backend.unblock(value, nil)
        task.transition!(:completed, value: value)
      end
      private_class_method :complete_task
    end
  end
end
