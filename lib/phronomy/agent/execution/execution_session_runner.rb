# frozen_string_literal: true

require_relative "../../execution/concurrency/worker_input_restricted"

module Phronomy
  module Agent
    # Registers ordinary and resumed Agent/Tool sessions on EventLoop.
    # ExecutionCoordinator owns admission and terminal persistence; this object
    # only wires the live sessions and reports their completion to that owner.
    # @api private
    class ExecutionSessionRunner
      include Phronomy::Concurrency::WorkerInputRestricted

      def initialize(environment:, on_complete:)
        @on_complete = on_complete
        @environment = environment
      end

      def register(session, result_task, source_name: "#{result_task.name}-source")
        assert_event_loop!
        source = Phronomy::TaskResult.deferred(name: source_name)
        source.on_complete do |invocation, error|
          @on_complete.call(
            execution_id: session.context.execution_id,
            result_task: result_task,
            invocation: invocation || session.context,
            error: error,
            fsm_session_id: session.id
          )
        end
        @environment.register_session(session, completion: source)
        session
      end

      def resume(invocation, result_task, resume_event:, resume_phase:,
        source_name: "#{result_task.name}-source")
        assert_event_loop!
        session = @environment.build_agent_session(
          invocation: invocation,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
        @environment.registry.replace_agent_execution(
          invocation.execution_id,
          invocation: invocation,
          fsm_session_id: session.id
        )
        register(session, result_task, source_name: source_name)
      end

      def resume_approval(invocation, result_task, approved:, config:)
        assert_event_loop!
        invocation.merge_config!(config)
        invocation.begin_approval_resume!(approved: approved)
        parent = resume(invocation, result_task,
          resume_event: :resume, resume_phase: :suspended)
        invocation.tool_invocations.each do |child|
          session = if child.awaiting_approval?
            @environment.build_tool_session(
              invocation: child,
              parent_sink: parent.event_sink,
              resume_event: approved ? :approve : :reject,
              resume_phase: :awaiting_approval
            )
          elsif !approved && child.authorized?
            @environment.build_tool_session(
              invocation: child,
              parent_sink: parent.event_sink,
              resume_event: :cancel,
              resume_phase: :authorized
            )
          end
          register_child(child, session, parent.event_sink) if session
        end
      end

      def resume_framework_tools(invocation, result_task)
        assert_event_loop!
        parent = resume(invocation, result_task,
          resume_event: :resume, resume_phase: :suspended,
          source_name: "framework-tool-recovery-source")
        invocation.tool_invocations.select(&:authorized?).each do |child|
          session = @environment.build_tool_session(
            invocation: child,
            parent_sink: parent.event_sink,
            resume_event: :dispatch,
            resume_phase: :authorized
          )
          register_child(child, session, parent.event_sink)
        end
      end

      private

      def register_child(child, session, parent_event_sink)
        completion = Phronomy::TaskResult.deferred(name: "tool-session:#{child.id}")
        completion.on_complete do |_result, error|
          next unless error

          child.mark_framework_failed!(error)
          parent_event_sink.post(:tool_failed, {tool_invocation_id: child.id})
        end
        @environment.register_session(session, completion: completion)
      end

      def assert_event_loop!
        return if @environment.executing?

        raise Phronomy::Error, "Agent session registration must run on EventLoop"
      end
    end
  end
end
