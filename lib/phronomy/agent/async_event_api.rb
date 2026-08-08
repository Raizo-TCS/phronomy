# frozen_string_literal: true

module Phronomy
  module Agent
    # Public Agent execution API. Agent instances are always stateful and all
    # operations are coordinated through Phronomy::Persistence.
    module AsyncEventApi
      def invoke(input, thread_id: nil, config: {}, invocation_context: nil, on_event: nil)
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        _check_scheduler_reentrancy(:invoke, :invoke_async)
        trace("agent.invoke", input: input, **_build_caller_meta(config)) do |_span|
          result = invoke_async(
            input,
            thread_id: thread_id,
            config: config,
            on_event: on_event
          ).wait_result
          [result, result[:usage]]
        end
      end

      def invoke_async(
        input,
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_tool_approval_required: nil,
        on_event: nil
      )
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        approval = _approval_configuration_snapshot(on_tool_approval_required)
        execution_coordinator.start(
          input,
          thread_id: thread_id,
          config: config,
          mode: :invoke,
          approval_policy: approval[:policy],
          approval_listener: approval[:listener],
          on_event: on_event
        )
      end

      def stream(
        input,
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_tool_approval_required: nil,
        on_event: nil,
        &block
      )
        listener = resolve_event_listener(on_event, block)
        raise ArgumentError, "stream requires on_event: or a block" unless listener
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        _check_scheduler_reentrancy(:stream, :stream_async)
        trace("agent.stream", input: input, **_build_caller_meta(config)) do |_span|
          result = stream_async(
            input,
            thread_id: thread_id,
            config: config,
            on_tool_approval_required: on_tool_approval_required,
            on_event: listener
          ).wait_result
          [result, result[:usage]]
        end
      end

      def stream_async(
        input,
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_tool_approval_required: nil,
        on_event: nil,
        &block
      )
        listener = resolve_event_listener(on_event, block)
        raise ArgumentError, "stream_async requires on_event: or a block" unless listener
        if invocation_context
          thread_id, config = _apply_invocation_context(thread_id, config, invocation_context)
        end
        approval = _approval_configuration_snapshot(on_tool_approval_required)
        execution_coordinator.start(
          input,
          thread_id: thread_id,
          config: config,
          mode: :stream,
          approval_policy: approval[:policy],
          approval_listener: approval[:listener],
          on_event: listener
        )
      end

      def approve(execution_id, approval_request_id:, approved: true, config: {})
        _check_scheduler_reentrancy(:approve, :approve_async)
        approve_async(
          execution_id,
          approval_request_id: approval_request_id,
          approved: approved,
          config: config
        ).wait_result
      end

      def approve_async(execution_id, approval_request_id:, approved: true, config: {})
        execution_coordinator.resume(
          execution_id,
          approval_request_id: approval_request_id,
          approved: approved,
          config: config
        )
      end

      private

      def execution_coordinator
        @execution_coordinator ||= Agent::ExecutionCoordinator.new(self)
      end

      def resolve_event_listener(keyword_listener, block_listener)
        if keyword_listener && block_listener
          raise ArgumentError, "Provide either on_event: or a block, not both"
        end
        keyword_listener || block_listener
      end
    end
  end
end
