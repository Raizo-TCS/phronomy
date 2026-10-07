# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent-owned entry operations and external-result delivery.
    # Session construction and resource selection are supplied by the environment.
    # @api private
    class InvocationActions
      def self.build_entry_actions(agent, environment, mode:, event_sink:)
        calling_action = if mode.to_sym == :stream
          method(:calling_llm_stream_action).curry.call(agent, environment, event_sink)
        else
          method(:calling_llm_action).curry.call(agent, environment, event_sink)
        end

        {
          filtering_input: [method(:apply_prepared_input_action).curry.call(agent)],
          building_context: [method(:prepare_runtime_input_action).curry.call(agent)],
          calling_llm: [calling_action],
          starting_tools: [method(:starting_tools_action).curry.call(environment, event_sink)],
          dispatching_tools: [method(:dispatching_tools_action).curry.call(environment, event_sink)],
          recording_tool_results: [method(:recording_tool_results_action)],
          suspended: [method(:suspended_action)],
          output_filtering: [method(:output_filtering_action).curry.call(agent)],
          failed: [method(:failed_action)]
        }
      end

      def self.apply_prepared_input_action(_agent, invocation)
        invocation.input = invocation.config.fetch(:phronomy_filtered_input)
        invocation
      end
      private_class_method :apply_prepared_input_action

      def self.prepare_runtime_input_action(agent, invocation)
        projection = invocation.config.fetch(:phronomy_runtime_projection)
        agent.send(:prepare_runtime_input, projection, invocation: invocation)
      end
      private_class_method :prepare_runtime_input_action

      def self.calling_llm_action(agent, environment, event_sink, invocation)
        prepare_and_start_llm_call(agent, environment, event_sink, invocation, streaming: false)
        invocation
      end
      private_class_method :calling_llm_action

      def self.calling_llm_stream_action(agent, environment, event_sink, invocation)
        prepare_and_start_llm_call(agent, environment, event_sink, invocation, streaming: true)
        invocation
      end
      private_class_method :calling_llm_stream_action

      def self.prepare_and_start_llm_call(agent, environment, event_sink, invocation, streaming:)
        # Callback failure is recorded synchronously on EventLoop before its
        # explicit failure event is queued. Do not start a competing durable
        # follow-up operation from the same execution revision while that failure
        # event is waiting to terminalize the FSMSession.
        return if invocation.callback_failed?

        if invocation.user_message_sent
          invocation.config.fetch(:phronomy_execution_coordinator).prepare_provider_dispatch(
            invocation,
            event_sink: event_sink,
            streaming: streaming
          )
        else
          start_provider_call(
            agent,
            environment,
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
        environment:,
        event_sink:,
        invocation:,
        projection:,
        streaming:
      )
        start_provider_call(
          agent,
          environment,
          event_sink,
          invocation,
          projection,
          streaming: streaming,
          replace_messages: true
        )
      end

      def self.start_provider_call(
        agent, environment, event_sink, invocation, projection,
        streaming:, replace_messages:
      )
        call_context = trace_handle = nil
        config = invocation.config
        agent.send(:check_cancellation!, config, "invocation cancelled before LLM call")
        if replace_messages
          agent.send(:prepare_runtime_input, projection, invocation: invocation)
          invocation.config[:phronomy_runtime_projection] = projection
        end

        request = agent.send(:build_llm_request, projection, invocation: invocation)
        state = environment.registry.agent_execution_state(invocation.execution_id)
        call_context = invocation.begin_llm_call!(projection,
          llm_call_id: state&.execution&.metadata&.fetch(ExecutionMetadata::PENDING_LLM_ID_KEY, nil))
        message = request.message
        trace_handle = Phronomy::Tracing::Automatic.start(
          "llm.call",
          input: message,
          agent_id: agent.agent_id,
          execution_id: invocation.execution_id,
          llm_call_id: call_context.fetch(:llm_call_id),
          mode: invocation.mode,
          streaming: streaming,
          **agent.send(:_build_caller_meta, config)
        )

        client = environment.build_llm_client(adapter: Phronomy::Agent::Settings.current.llm_adapter)
        token = config[:cancellation_token]
        llm_call_id = call_context.fetch(:llm_call_id)
        operation = if streaming
          client.stream_async(
            request, cancellation_token: config[:cancellation_token]
          ) do |chunk|
            token&.raise_if_cancelled!("invocation cancelled during streaming")
            post_stream_chunk(
              event_sink,
              llm_call_id,
              chunk.content
            )
          end
        else
          client.complete_async(
            request, cancellation_token: config[:cancellation_token]
          )
        end
        environment.registry.supervise_agent_operation(
          invocation.execution_id,
          operation
        )
        observe_manifest_call(
          operation,
          event_sink,
          call_context,
          trace_handle,
          streaming: streaming
        )
      rescue => error
        finish_provider_trace(trace_handle, nil, error)
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

      def self.observe_manifest_call(
        operation,
        event_sink,
        call_context,
        trace_handle,
        streaming:
      )
        operation.on_complete do |response, error|
          finish_provider_trace(trace_handle, response, error)
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

      def self.finish_provider_trace(trace_handle, response, error)
        Phronomy::Tracing::Automatic.finish(trace_handle,
          output: response, usage: response&.usage, error: error)
      end
      private_class_method :finish_provider_trace

      def self.post_llm_result(event_sink, call_context, response, error, streaming:)
        result = LLMOperationResult.new(
          llm_call_id: call_context.fetch(:llm_call_id),
          response: response,
          error: error,
          streaming: streaming
        )
        event_type = if error
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

        Phronomy::RuntimeSettings.current.logger&.warn(
          "[Phronomy] Dropped late #{event_type.inspect} for " \
          "FSMSession #{event_sink.fsm_session_id}"
        )
      end
      private_class_method :post_session_event!

      def self.starting_tools_action(environment, parent_event_sink, invocation)
        children = invocation.pending_tool_calls.map do |tool_call|
          tool = invocation.tools[tool_call.name.to_sym]
          tool_invocation_id =
            ToolInvocation.semantic_id(
              execution_id: invocation.execution_id,
              llm_call_id: invocation.tool_batch_llm_call_id,
              tool_call_id: (
                tool_call.respond_to?(:id) ? tool_call.id : nil
              ),
              tool_name: tool_call.name
            )

          if tool
            ToolInvocation.new(
              execution_id: invocation.execution_id,
              agent: invocation.agent,
              tool: tool,
              tool_call: tool_call,
              config: invocation.config,
              approval_policy: invocation.approval_policy,
              approval_context: invocation.approval_context,
              id: tool_invocation_id
            )
          else
            ToolInvocation.missing(
              execution_id: invocation.execution_id,
              agent: invocation.agent,
              tool_call: tool_call,
              config: invocation.config,
              id: tool_invocation_id
            )
          end
        end
        invocation.tool_invocations = children

        children.reject(&:terminal?).each do |child|
          session = environment.build_tool_session(invocation: child, parent_sink: parent_event_sink)
          register_child_session(
            environment,
            child,
            session,
            parent_event_sink
          )
        end
        invocation
      end
      private_class_method :starting_tools_action

      def self.dispatching_tools_action(_environment, parent_event_sink, invocation)
        invocation.config.fetch(:phronomy_execution_coordinator).prepare_tool_dispatch(
          invocation,
          event_sink: parent_event_sink
        )
        invocation
      end
      private_class_method :dispatching_tools_action

      # Continues Tool physical dispatch after the operation-specific durable
      # preparation has been confirmed and applied by ExecutionCoordinator.
      # @api private
      def self.start_prepared_tool_dispatch(
        environment:,
        event_sink:,
        invocation:
      )
        invocation.tool_invocations.select(&:authorized?).each do |child|
          session = environment.build_tool_session(
            invocation: child,
            parent_sink: event_sink,
            resume_event: :dispatch,
            resume_phase: :authorized
          )
          begin
            register_child_session(environment, child, session, event_sink)
          rescue => error
            child.mark_framework_failed!(error)
            event_sink.post(:tool_failed, {tool_invocation_id: child.id})
          end
        end
        post_session_event!(event_sink, :tool_dispatch_prepared, nil)
        invocation
      end

      def self.register_child_session(environment, child, session, parent_event_sink)
        completion = Phronomy::TaskResult.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          # Tool FSMSession completion is settled by EventLoop, so this callback
          # also executes on EventLoop and remains inside the single-writer domain.
          child.mark_framework_failed!(error)
          parent_event_sink.post(:tool_failed, {tool_invocation_id: child.id})
        end
        environment.register_session(session, completion: completion)
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
