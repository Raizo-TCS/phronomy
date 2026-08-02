# frozen_string_literal: true

module Phronomy
  module Agent
    # Symmetric Agent async event contract layered onto Agent::Base.
    #
    # invoke_async and stream_async share lifecycle/tool events. stream_async
    # additionally emits :token events. The returned Task remains a normal Task
    # and is settled after the terminal event listener returns.
    #
    # @api private
    module AsyncEventApi
      # Invokes the agent synchronously and returns the terminal result.
      #
      # Provider errors are translated after the configured LLM adapter returns
      # its final result. Phronomy does not replay the Agent invocation.
      #
      # @param input [String, Hash] user input for this invocation
      # @param messages [Array<RubyLLM::Message>] conversation history
      # @param thread_id [String, nil] conversation thread identifier
      # @param config [Hash] additional runtime options
      # @param invocation_context [Phronomy::InvocationContext, nil]
      #   first-class invocation context
      # @param on_event [Proc, nil] listener for lifecycle and Tool events
      # @return [Hash] terminal invocation result
      # @raise [Phronomy::SchedulerReentrancyError] when called from the
      #   EventLoop thread or a guarded scheduler context
      # @api public
      def invoke(
        input,
        messages: [],
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_event: nil
      )
        if invocation_context
          thread_id, config = _apply_invocation_context(
            thread_id,
            config,
            invocation_context
          )
        end
        _check_scheduler_reentrancy(:invoke, :invoke_async)

        trace(
          "agent.invoke",
          input: input,
          **_build_caller_meta(config)
        ) do |_span|
          result = invoke_async(
            input,
            messages: messages,
            thread_id: thread_id,
            config: config,
            on_event: on_event
          ).wait_result
          [result, result[:usage]]
        end
      end

      # Invokes the agent asynchronously.
      #
      # The returned Task settles after the terminal event listener returns.
      # Lifecycle and Tool events are delivered from the Runtime-owned
      # EventLoop thread.
      #
      # @param input [String, Hash] user input for this invocation
      # @param messages [Array<RubyLLM::Message>] conversation history
      # @param thread_id [String, nil] conversation thread identifier
      # @param config [Hash] additional runtime options
      # @param invocation_context [Phronomy::InvocationContext, nil]
      #   first-class invocation context
      # @param on_tool_approval_required [Proc, nil] per-invocation approval
      #   notification listener
      # @param on_event [Proc, nil] listener for lifecycle and Tool events
      # @return [Phronomy::Task] Task resolving to the terminal result
      # @api public
      def invoke_async(
        input,
        messages: [],
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_tool_approval_required: nil,
        on_event: nil
      )
        if invocation_context
          thread_id, config = _apply_invocation_context(
            thread_id,
            config,
            invocation_context
          )
        end

        result_task = Phronomy::Task.deferred(
          name:
            "agent-#{(self.class.name || "anonymous").downcase}-async"
        )
        approval_snapshot = _approval_configuration_snapshot(
          on_tool_approval_required
        )
        _start_invocation(
          result_task,
          input,
          messages: messages,
          thread_id: thread_id,
          config: config,
          approval_snapshot: approval_snapshot,
          mode: :invoke,
          on_event: on_event
        )
        result_task
      end

      # Invokes the agent asynchronously and emits streaming events.
      #
      # Accepts either +on_event:+ or a block. Supplying both is rejected.
      # Token events are emitted only by streaming invocations; lifecycle and
      # Tool events use the same contract as {#invoke_async}.
      #
      # @param input [String, Hash] user input for this invocation
      # @param messages [Array<RubyLLM::Message>] conversation history
      # @param thread_id [String, nil] conversation thread identifier
      # @param config [Hash] additional runtime options
      # @param invocation_context [Phronomy::InvocationContext, nil]
      #   first-class invocation context
      # @param on_tool_approval_required [Proc, nil] per-invocation approval
      #   notification listener
      # @param on_event [Proc, nil] event listener
      # @yieldparam event [Phronomy::Agent::StreamEvent]
      # @return [Phronomy::Task] Task resolving to the terminal result
      # @raise [ArgumentError] when no listener is supplied or both listener
      #   forms are supplied
      # @api public
      def stream_async(
        input,
        messages: [],
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_tool_approval_required: nil,
        on_event: nil,
        &block
      )
        listener = resolve_event_listener(on_event, block)
        unless listener
          raise ArgumentError,
            "stream_async requires on_event: or a block"
        end

        if invocation_context
          thread_id, config = _apply_invocation_context(
            thread_id,
            config,
            invocation_context
          )
        end

        result_task = Phronomy::Task.deferred(
          name:
            "agent-#{(self.class.name || "anonymous").downcase}" \
            "-stream-async"
        )
        approval_snapshot = _approval_configuration_snapshot(
          on_tool_approval_required
        )
        _start_invocation(
          result_task,
          input,
          messages: messages,
          thread_id: thread_id,
          config: config,
          approval_snapshot: approval_snapshot,
          mode: :stream,
          on_event: listener
        )
        result_task
      end

      # Invokes the agent synchronously and emits streaming events.
      #
      # Accepts either +on_event:+ or a block. Event callbacks run on the
      # Runtime-owned EventLoop thread; the calling thread waits for the final
      # Task result.
      #
      # @param input [String, Hash] user input for this invocation
      # @param messages [Array<RubyLLM::Message>] conversation history
      # @param thread_id [String, nil] conversation thread identifier
      # @param config [Hash] additional runtime options
      # @param invocation_context [Phronomy::InvocationContext, nil]
      #   first-class invocation context
      # @param on_tool_approval_required [Proc, nil] per-invocation approval
      #   notification listener
      # @param on_event [Proc, nil] event listener
      # @yieldparam event [Phronomy::Agent::StreamEvent]
      # @return [Hash] terminal invocation result
      # @raise [ArgumentError] when no listener is supplied or both listener
      #   forms are supplied
      # @raise [Phronomy::SchedulerReentrancyError] when called from the
      #   EventLoop thread or a guarded scheduler context
      # @api public
      def stream(
        input,
        messages: [],
        thread_id: nil,
        config: {},
        invocation_context: nil,
        on_tool_approval_required: nil,
        on_event: nil,
        &block
      )
        listener = resolve_event_listener(on_event, block)
        unless listener
          raise ArgumentError,
            "stream requires on_event: or a block"
        end

        if invocation_context
          thread_id, config = _apply_invocation_context(
            thread_id,
            config,
            invocation_context
          )
        end
        _check_scheduler_reentrancy(:stream, :stream_async)

        trace(
          "agent.stream",
          input: input,
          **_build_caller_meta(config)
        ) do |_span|
          result = stream_async(
            input,
            messages: messages,
            thread_id: thread_id,
            config: config,
            on_tool_approval_required:
              on_tool_approval_required,
            on_event: listener
          ).wait_result
          [result, result[:usage]]
        end
      end

      private

      def resolve_event_listener(keyword_listener, block_listener)
        if keyword_listener && block_listener
          raise ArgumentError,
            "Provide either on_event: or a block, not both"
        end
        keyword_listener || block_listener
      end

      # Installs the Application listener before EventLoop admission.
      # Cancellation is checked by the first Agent entry action on the EventLoop
      # thread so even pre-cancelled invocations produce a terminal event before
      # the returned Task settles.
      # @api private
      def _start_invocation(
        result_task,
        input,
        messages:,
        thread_id:,
        config:,
        approval_snapshot:,
        mode: :invoke,
        on_event: nil
      )
        effective_config =
          thread_id ? config.merge(thread_id: thread_id) : config
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        session = Agent::AgentInvocationSessionBuilder.build(
          agent: self,
          input: input,
          messages: messages,
          config: effective_config,
          approval_policy: approval_snapshot[:policy],
          approval_listener: approval_snapshot[:listener],
          mode: mode,
          on_event: on_event,
          runtime: runtime
        )
        callback_error_policy =
          Phronomy.configuration.stream_callback_error_policy
        source_task = Phronomy::Task.deferred(
          name: "#{result_task.name}-source"
        )
        source_task.on_complete do |invocation, error|
          completed_invocation = invocation || session.context
          _handle_agent_completion(
            result_task: result_task,
            invocation: completed_invocation,
            error: error,
            mode: mode,
            listener: on_event,
            event_loop: event_loop,
            callback_error_policy: callback_error_policy
          )
        end

        event_loop.register(session, completion: source_task)
      rescue => error
        _fail_result_task(result_task, error)
      end

      def _handle_agent_completion(
        result_task:,
        invocation:,
        error:,
        mode:,
        listener:,
        event_loop:,
        callback_error_policy:
      )
        if listener && !event_loop.current?
          completion_error = error || Phronomy::Error.new(
            "Agent event delivery occurred outside the EventLoop"
          )
          _fail_result_task(
            result_task,
            _translated_error(completion_error)
          )
          return
        end

        result = nil
        execution_error = nil
        begin
          raise error if error

          result = _extract_invoke_result(invocation)
        rescue => caught
          execution_error = _translated_error(caught)
        end
        if execution_error
          execution_error = normalize_terminal_error(
            execution_error,
            invocation
          )
        end

        if execution_error
          terminal_event = StreamEvent.new(
            type: terminal_error_event_type(execution_error),
            payload: {error: execution_error}
          )
          callback_error = _deliver_stream_event(
            listener,
            terminal_event
          )
          if callback_error
            report_agent_event_callback_error(
              callback_error,
              event: terminal_event,
              invocation_id: invocation&.id,
              callback_error_policy: callback_error_policy
            )
          end

          # Listener failure never replaces an Agent execution failure.
          _fail_result_task(result_task, execution_error)
          return
        end

        terminal_event = _build_stream_terminal_event(result)
        callback_error = _deliver_stream_event(
          listener,
          terminal_event
        )

        unless callback_error
          _complete_result_task(result_task, result)
          return
        end

        report_agent_event_callback_error(
          callback_error,
          event: terminal_event,
          invocation_id: invocation&.id,
          callback_error_policy: callback_error_policy
        )

        if callback_error_policy == :fail_task
          wrapped = _build_stream_callback_error(
            event_type: terminal_event.type,
            callback_error: callback_error,
            result: result
          )
          _fail_result_task(result_task, wrapped)
        else
          _complete_result_task(result_task, result)
        end
      end

      def terminal_error_event_type(error)
        case error
        when Phronomy::TimeoutError
          :timeout
        when Phronomy::CancellationError
          :cancelled
        else
          :error
        end
      end

      def normalize_terminal_error(error, invocation)
        return error unless error.is_a?(Phronomy::CancellationError)
        return error unless invocation_timeout_expired?(invocation)

        timeout_error = Phronomy::TimeoutError.new(error.message)
        timeout_error.set_backtrace(error.backtrace)
        timeout_error
      end

      def invocation_timeout_expired?(invocation)
        config = invocation&.config || {}
        invocation_context = config[:invocation_context]
        deadline = invocation_context&.deadline
        return true if deadline&.expired?

        token = config[:cancellation_token]
        return false unless token

        remaining =
          if token.respond_to?(:remaining_monotonic_seconds)
            token.remaining_monotonic_seconds
          end
        return true if remaining == 0.0

        wall_deadline = token.deadline if token.respond_to?(:deadline)
        wall_deadline && Time.now >= wall_deadline
      end

      def report_agent_event_callback_error(
        callback_error,
        event:,
        invocation_id:,
        callback_error_policy:
      )
        _report_stream_callback_error(
          callback_error,
          event: event,
          invocation_id: invocation_id,
          callback_error_policy: callback_error_policy
        )
      end

      def _register_tool_invocation_session(
        event_loop,
        runtime,
        child,
        session
      )
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
        event_loop.register(session, completion: completion)
      end

      # Resumes a suspended AgentInvocation and its pending Tool sessions.
      #
      # Parent completion handling is installed before EventLoop registration,
      # and the parent session is registered before child sessions so immediate
      # child events cannot be lost.
      # @api private
      def _start_approval_resume(
        result_task,
        invocation,
        approved:,
        config:
      )
        invocation.merge_config!(config)
        invocation.begin_approval_resume!(approved: approved)
        runtime = Phronomy::Runtime.instance
        event_loop = runtime.event_loop
        source_task = Phronomy::Task.deferred(
          name: "#{result_task.name}-source"
        )
        parent_session =
          Agent::AgentInvocationSessionBuilder.build_for_resume(
            agent_invocation: invocation,
            resume_event: :resume,
            resume_phase: :suspended,
            runtime: runtime
          )
        listener = invocation.event_listener
        mode = invocation.mode
        callback_error_policy =
          Phronomy.configuration.stream_callback_error_policy

        source_task.on_complete do |completed_invocation, error|
          invocation_result = completed_invocation || parent_session.context
          _handle_agent_completion(
            result_task: result_task,
            invocation: invocation_result,
            error: error,
            mode: mode,
            listener: listener,
            event_loop: event_loop,
            callback_error_policy: callback_error_policy
          )
        end

        event_loop.register(
          parent_session,
          completion: source_task
        )

        invocation.tool_invocations.each do |child|
          child_session =
            if child.awaiting_approval?
              Agent::ToolInvocationSessionBuilder.build_for_resume(
                tool_invocation: child,
                resume_event: approved ? :approve : :reject,
                resume_phase: :awaiting_approval,
                runtime: runtime
              )
            elsif !approved && child.authorized?
              Agent::ToolInvocationSessionBuilder.build_for_resume(
                tool_invocation: child,
                resume_event: :cancel,
                resume_phase: :authorized,
                runtime: runtime
              )
            end
          if child_session
            _register_tool_invocation_session(
              event_loop,
              runtime,
              child,
              child_session
            )
          end
        end
      end
    end
  end
end
