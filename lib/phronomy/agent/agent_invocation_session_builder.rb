# frozen_string_literal: true

module Phronomy
  module Agent
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
        recording_tool_results suspended output_filtering handed_off completed blocked failed
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
          config: config,
          approval_policy: approval_policy,
          approval_listener: approval_listener,
          event_listener: on_event,
          mode: mode,
          execution_id: config.fetch(:execution_id)
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
        event_sink = Phronomy::FSMSession::EventSink.new(
          event_loop: runtime.event_loop
        )
        agent_invocation.bind_event_sink!(event_sink)
        actions = build_entry_actions(
          agent, runtime, mode: mode, event_sink: event_sink
        )
        phase_machine = Agent::PhaseMachineBuilder.new(entry_actions: actions).build
        iterations = agent.class.max_iterations || 10

        Phronomy::FSMSession.new(
          context: agent_invocation,
          event_sink: event_sink,
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
          [event_name, [{from: :waiting_for_tools, to: :evaluating_tools, guard: nil}]]
        end

        tool_transitions.merge(
          llm_completed: [
            {from: :calling_llm, to: :failed, guard: ->(ctx) { ctx.callback_failed? }},
            {from: :calling_llm, to: :failed, guard: ->(ctx) { ctx.handoff_failed? }},
            {from: :calling_llm, to: :handed_off, guard: ->(ctx) { ctx.handoff_requested? }},
            {from: :calling_llm, to: :starting_tools, guard: ->(ctx) { ctx.tool_call_pending? }},
            {from: :calling_llm, to: :output_filtering, guard: nil}
          ],
          llm_failed: [
            {from: :calling_llm, to: :failed, guard: nil}
          ],
          llm_setup_failed: [
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

      def self.build_entry_actions(agent, runtime, mode:, event_sink:)
        calling_action = if mode.to_sym == :stream
          method(:calling_llm_stream_action).curry.call(agent, runtime, event_sink)
        else
          method(:calling_llm_action).curry.call(agent, runtime, event_sink)
        end

        {
          filtering_input: [method(:filtering_input_action).curry.call(agent)],
          building_context: [method(:building_context_action).curry.call(agent)],
          calling_llm: [calling_action],
          starting_tools: [method(:starting_tools_action).curry.call(runtime, event_sink)],
          dispatching_tools: [method(:dispatching_tools_action).curry.call(runtime, event_sink)],
          recording_tool_results: [method(:recording_tool_results_action)],
          suspended: [method(:suspended_action)],
          output_filtering: [method(:output_filtering_action).curry.call(agent)],
          failed: [method(:failed_action)]
        }
      end
      private_class_method :build_entry_actions

      def self.filtering_input_action(_agent, invocation)
        invocation.input = invocation.config.fetch(:phronomy_filtered_input)
        invocation
      end
      private_class_method :filtering_input_action

      def self.building_context_action(agent, invocation)
        projection = invocation.config.fetch(:phronomy_runtime_projection)
        invocation.chat = agent.send(:build_chat, model_config: projection.model_config)
        agent.send(
          :_apply_runtime_projection_to_chat,
          invocation.chat,
          projection,
          invocation: invocation
        )
        invocation
      end
      private_class_method :building_context_action

      def self.install_tool_interceptors(chat, llm_call_id:)
        unless chat.respond_to?(:before_tool_call)
          raise Phronomy::ConfigurationError,
            "Agent-owned Tool execution requires RubyLLM >= 1.15 (before_tool_call callback)"
        end

        if chat.respond_to?(:on_tool_call_batch)
          chat.on_tool_call_batch do |tool_calls|
            raise build_tool_interception(chat, tool_calls, llm_call_id)
          end
        end

        chat.before_tool_call do |tool_call|
          raise build_tool_interception(chat, [tool_call], llm_call_id)
        end
      end
      private_class_method :install_tool_interceptors

      def self.build_tool_interception(chat, fallback_tool_calls, llm_call_id)
        assistant_message = chat.messages.last
        unless assistant_message&.respond_to?(:role) &&
            assistant_message.role.to_sym == :assistant &&
            assistant_message.respond_to?(:tool_calls)
          raise Phronomy::Error,
            "RubyLLM Tool callback fired before the complete assistant message was observable"
        end

        message_tool_calls = assistant_message.tool_calls
        tool_calls = message_tool_calls.respond_to?(:values) ? message_tool_calls.values : Array(message_tool_calls)
        tool_calls = Array(fallback_tool_calls) if tool_calls.empty?

        ToolCallIntercepted.new(
          tool_calls,
          assistant_message: assistant_message,
          assistant_outcome: ProviderCallOutcome.capture(assistant_message),
          llm_call_id: llm_call_id
        )
      end
      private_class_method :build_tool_interception

      def self.calling_llm_action(agent, runtime, event_sink, invocation)
        prepare_and_start_llm_call(agent, runtime, event_sink, invocation, streaming: false)
        invocation
      end
      private_class_method :calling_llm_action

      def self.calling_llm_stream_action(agent, runtime, event_sink, invocation)
        prepare_and_start_llm_call(agent, runtime, event_sink, invocation, streaming: true)
        invocation
      end
      private_class_method :calling_llm_stream_action

      def self.prepare_and_start_llm_call(agent, runtime, event_sink, invocation, streaming:)
        # Callback failure is recorded synchronously on EventLoop before its
        # explicit failure event is queued. Do not start a competing durable
        # follow-up operation from the same execution revision while that failure
        # event is waiting to terminalize the FSMSession.
        return if invocation.callback_failed?

        if invocation.user_message_sent
          invocation.config.fetch(:phronomy_execution_coordinator).prepare_next_llm_call(
            invocation,
            event_sink: event_sink,
            streaming: streaming
          )
        else
          start_provider_call(
            agent,
            runtime,
            event_sink,
            invocation,
            invocation.config.fetch(:phronomy_runtime_projection),
            streaming: streaming,
            replace_messages: false
          )
        end
      rescue => error
        post_setup_failure(event_sink, error)
      end
      private_class_method :prepare_and_start_llm_call

      # Continues a follow-up Provider Call after its durable preparation result
      # has been validated/applied by ExecutionCoordinator on EventLoop.
      # @api private
      def self.start_prepared_provider_call(
        agent:,
        runtime:,
        event_sink:,
        invocation:,
        projection:,
        streaming:
      )
        start_provider_call(
          agent,
          runtime,
          event_sink,
          invocation,
          projection,
          streaming: streaming,
          replace_messages: true
        )
      end

      def self.start_provider_call(
        agent, runtime, event_sink, invocation, projection,
        streaming:, replace_messages:
      )
        call_context = nil
        config = invocation.config
        agent.send(:check_cancellation!, config, "invocation cancelled before LLM call")
        if replace_messages
          invocation.chat = agent.send(:build_chat, model_config: projection.model_config)
          agent.send(
            :_apply_runtime_projection_to_chat,
            invocation.chat,
            projection,
            invocation: invocation
          )
          invocation.config[:phronomy_runtime_projection] = projection
        end

        call_context = invocation.begin_llm_call!(projection)
        install_tool_interceptors(
          invocation.chat,
          llm_call_id: call_context.fetch(:llm_call_id)
        )
        message = projection.ask_message
        chat = invocation.chat

        operation = if streaming
          Phronomy.configuration.llm_adapter.stream_async(
            chat, message, config: config
          ) do |chunk|
            token = config[:cancellation_token]
            token&.raise_if_cancelled!("invocation cancelled during streaming")
            post_stream_chunk(
              event_sink,
              call_context.fetch(:llm_call_id),
              chunk.content
            )
          end
        else
          Phronomy.configuration.llm_adapter.complete_async(
            chat, message, config: config
          )
        end
        runtime.event_loop.supervise_agent_operation(
          invocation.execution_id,
          operation
        )
        observe_manifest_call(
          operation,
          event_sink,
          call_context,
          streaming: streaming
        )
      rescue => error
        if call_context
          post_llm_result(
            event_sink,
            call_context,
            nil,
            error,
            streaming: streaming
          )
        else
          post_setup_failure(event_sink, error)
        end
      end
      private_class_method :start_provider_call

      def self.observe_manifest_call(operation, event_sink, call_context, streaming:)
        operation.on_complete do |response, error|
          post_llm_result(
            event_sink,
            call_context,
            response,
            error,
            streaming: streaming
          )
        end
      end
      private_class_method :observe_manifest_call

      def self.post_llm_result(event_sink, call_context, response, error, streaming:)
        result = LLMOperationResult.new(
          llm_call_id: call_context.fetch(:llm_call_id),
          response: response,
          error: error,
          streaming: streaming
        )
        event_type = if error && !error.is_a?(ToolCallIntercepted)
          :llm_failed
        else
          :llm_completed
        end
        post_session_event!(event_sink, event_type, result)
      end
      private_class_method :post_llm_result

      def self.post_stream_chunk(event_sink, llm_call_id, content)
        post_session_event!(
          event_sink,
          :llm_stream_chunk,
          {llm_call_id: llm_call_id.to_s.freeze, content: content}.freeze
        )
      end
      private_class_method :post_stream_chunk

      def self.post_setup_failure(event_sink, error)
        post_session_event!(event_sink, :llm_setup_failed, error)
      end
      private_class_method :post_setup_failure

      def self.post_session_event!(event_sink, event_type, payload)
        return if event_sink.post(event_type, payload)

        Phronomy.configuration.logger&.warn(
          "[Phronomy] Dropped late #{event_type.inspect} for " \
          "FSMSession #{event_sink.fsm_session_id}"
        )
      end
      private_class_method :post_session_event!

      def self.starting_tools_action(runtime, parent_event_sink, invocation)
        children = invocation.pending_tool_calls.map do |tool_call|
          tool = invocation.chat.tools[tool_call.name.to_sym]
          if tool
            ToolInvocation.new(
              execution_id: invocation.execution_id,
              agent: invocation.agent,
              tool: tool,
              tool_call: tool_call,
              config: invocation.config,
              approval_policy: invocation.approval_policy,
              approval_context: invocation.approval_context
            )
          else
            ToolInvocation.missing(
              execution_id: invocation.execution_id,
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
            parent_event_sink: parent_event_sink,
            runtime: runtime
          )
          register_child_session(runtime, child, session, parent_event_sink)
        end
        invocation
      end
      private_class_method :starting_tools_action

      def self.dispatching_tools_action(runtime, parent_event_sink, invocation)
        invocation.tool_invocations.select(&:authorized?).each do |child|
          session = ToolInvocationSessionBuilder.build_for_resume(
            tool_invocation: child,
            parent_event_sink: parent_event_sink,
            resume_event: :dispatch,
            resume_phase: :authorized,
            runtime: runtime
          )
          register_child_session(runtime, child, session, parent_event_sink)
        end
        invocation
      end
      private_class_method :dispatching_tools_action

      def self.register_child_session(runtime, child, session, parent_event_sink)
        completion = Phronomy::Task.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          # Tool FSMSession completion is settled by EventLoop, so this callback
          # also executes on EventLoop and remains inside the single-writer domain.
          child.mark_framework_failed!(error)
          parent_event_sink.post(:tool_failed, {tool_invocation_id: child.id})
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
        raise(invocation.error || Phronomy::ToolError.new("Agent invocation failed"))
      end
      private_class_method :failed_action

      def self.output_filtering_action(agent, invocation)
        invocation.output = agent.send(:run_output_filters!, invocation.output)
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
