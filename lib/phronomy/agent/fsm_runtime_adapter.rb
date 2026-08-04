# frozen_string_literal: true

module Phronomy
  module Agent
    # Adapts the current AgentInvocation FSM to the ideal manifest-first model.
    # Every LLM Call receives a freshly fixed Manifest. Persistence and
    # projection preparation run on BlockingAdapterPool, never on EventLoop.
    module FsmRuntimeAdapter
      private

      def filtering_input_action(_agent, invocation)
        invocation.input = invocation.config.fetch(:phronomy_filtered_input)
        invocation
      end

      def building_context_action(agent, invocation)
        projection = invocation.config.fetch(:phronomy_runtime_projection)
        invocation.chat = agent.send(:build_chat, model_config: projection.model_config)
        agent.send(
          :_apply_context_to_chat,
          invocation.chat,
          {
            system: projection.system,
            messages: projection.messages,
            tool_classes: projection.tool_classes,
            model_config: projection.model_config
          }
        )
        agent.send(:run_before_completion_hooks!, invocation.chat, invocation.config)
        install_tool_interceptors(invocation.chat)
        invocation
      end

      def calling_llm_action(agent, runtime, invocation)
        prepare_and_start_llm_call(
          agent,
          runtime,
          invocation,
          streaming: false
        )
        invocation
      end

      def calling_llm_stream_action(agent, runtime, invocation)
        prepare_and_start_llm_call(
          agent,
          runtime,
          invocation,
          streaming: true
        )
        invocation
      end

      def prepare_and_start_llm_call(agent, runtime, invocation, streaming:)
        activation = invocation.config.fetch(:phronomy_activation)
        if invocation.user_message_sent
          preparation = runtime.blocking_io.submit do
            activation.coordinator.prepare_next_llm_call(activation)
          end
          preparation.on_complete do |projection, error|
            if error
              post_preparation_failure(runtime, invocation, error, streaming: streaming)
            else
              start_provider_call(
                agent,
                runtime,
                invocation,
                activation,
                projection,
                streaming: streaming,
                replace_messages: true
              )
            end
          end
        else
          start_provider_call(
            agent,
            runtime,
            invocation,
            activation,
            activation.runtime_projection,
            streaming: streaming,
            replace_messages: false
          )
        end
      end

      def start_provider_call(
        agent,
        runtime,
        invocation,
        activation,
        projection,
        streaming:,
        replace_messages:
      )
        agent.send(
          :check_cancellation!,
          invocation.config,
          "invocation cancelled before LLM call"
        )
        if replace_messages
          agent.send(:_replace_chat_messages, invocation.chat, projection)
          invocation.config[:phronomy_runtime_projection] = projection
        end
        activation.begin_llm_call(projection)
        message = projection.ask_message

        operation = if streaming
          Phronomy.configuration.llm_adapter.stream_async(
            invocation.chat,
            message,
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
        else
          Phronomy.configuration.llm_adapter.complete_async(
            invocation.chat,
            message,
            config: invocation.config
          )
        end
        observe_manifest_call(
          operation,
          activation,
          invocation,
          runtime: runtime,
          streaming: streaming
        )
      rescue => error
        activation.record_llm_result(
          response: nil,
          error: error,
          streaming: streaming
        )
        post_llm_result(runtime, invocation, nil, error, streaming: streaming)
      end

      def observe_manifest_call(operation, activation, invocation, runtime:, streaming:)
        operation.on_complete do |response, error|
          activation.record_llm_result(
            response: response,
            error: error,
            streaming: streaming
          )
          post_llm_result(
            runtime,
            invocation,
            response,
            error,
            streaming: streaming
          )
        end
      end

      def post_preparation_failure(runtime, invocation, error, streaming:)
        post_llm_result(runtime, invocation, nil, error, streaming: streaming)
      end

      def post_llm_result(runtime, invocation, response, error, streaming:)
        result = LLMOperationResult.new(
          response: response,
          error: error,
          streaming: streaming
        )
        event_type = if error && !error.is_a?(ToolCallIntercepted)
          :llm_failed
        else
          :llm_completed
        end
        post_to_invocation!(runtime, invocation.id, event_type, result)
      end
    end
  end
end
