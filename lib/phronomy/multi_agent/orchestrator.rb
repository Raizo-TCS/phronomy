# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Base class for orchestrator agents that coordinate multiple subagents.
    class Orchestrator < Agent::Base
      agent_definition id: "orchestrator", version: 1

      def self.subagent(name, agent_class, on_error: :raise, inherit_knowledge: true)
        # A subagent Tool is logically asynchronous: ToolInvocation starts the
        # child Agent and resumes when its completion Task settles. It must not
        # occupy an OffloadPool worker while waiting for the child.
        tool_class = Class.new(Phronomy::Tools::Agent) do
          tool_name "dispatch_to_#{name}"
          description "Dispatch work to the #{name} subagent (#{agent_class.name})"

          attr_writer :_orchestrator_context

          define_method(:execute) do |input:, cancellation_token: nil|
            execute_async(
              input: input,
              cancellation_token: cancellation_token,
              config: {}
            ).wait_result
          end

          define_method(:execute_async) do |input:, cancellation_token: nil, config: {}|
            ctx = @_orchestrator_context || {}
            parent_ic = ctx[:invocation_context]
            task_config = (ctx[:config] || {}).merge(config || {})

            if cancellation_token && !task_config[:cancellation_token]
              task_config = task_config.merge(cancellation_token: cancellation_token)
            end

            if parent_ic && !task_config[:invocation_context]
              child_ic = parent_ic.merge(parent_task_id: parent_ic.task_id)
              task_config = task_config.merge(invocation_context: child_ic)
            end

            agent = agent_class.new
            if inherit_knowledge
              Array(ctx[:knowledge]).each do |entry|
                agent.add_knowledge(
                  entry.fetch(:content),
                  metadata: entry.fetch(:metadata, {})
                )
              end
            end

            source = agent.invoke_async(
              input,
              thread_id: ctx[:thread_id] || parent_ic&.thread_id,
              config: task_config
            )
            result_task = Phronomy::Task.deferred(
              name: "subagent-tool-#{name}"
            )
            source.on_complete do |result, error|
              if error
                (on_error == :raise) ? result_task.fail(error) : result_task.complete(nil)
              else
                result_task.complete(result[:output])
              end
            end
            result_task
          rescue => error
            result_task ||= Phronomy::Task.deferred(
              name: "subagent-tool-#{name}"
            )
            (on_error == :raise) ? result_task.fail(error) : result_task.complete(nil)
            result_task
          end
          private :execute_async
        end

        @_subagent_tool_classes = (@_subagent_tool_classes || []) + [tool_class]
        @tools = (@tools || []) + [tool_class]
        @tool_aliases ||= {}
        registered_subagents[name] = {
          agent_class: agent_class,
          on_error: on_error,
          inherit_knowledge: inherit_knowledge
        }
      end

      def self._subagent_tool_classes
        @_subagent_tool_classes || []
      end

      def self.registered_subagents
        @registered_subagents ||= {}
      end

      def dispatch_parallel(
        *tasks,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        if Phronomy::Runtime.in_event_loop_context?
          raise Phronomy::EventLoopReentrancyError,
            "dispatch_parallel cannot block the EventLoop; use dispatch_parallel_async"
        end
        dispatch_parallel_async(
          *tasks,
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          inherit_knowledge: inherit_knowledge
        ).wait_result
      end

      def dispatch_parallel_async(
        *tasks,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        validate_parallel_options!(tasks, max_concurrency, on_error)
        return Phronomy::Task.deferred(name: "fan-out-empty").tap { |task| task.complete([]) } if tasks.empty?

        children = build_fan_out_children(
          tasks,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          inherit_knowledge: inherit_knowledge
        )
        invocation = FanOutInvocation.new(
          children: children,
          max_concurrency: max_concurrency || children.length,
          on_error: on_error
        )
        effective_token = cancellation_token || invocation_context&.cancellation_token
        FanOutSessionBuilder.start(
          invocation: invocation,
          timeout: timeout,
          cancellation_token: effective_token
        )
      end

      def fan_out(
        agent:,
        inputs:,
        config: {},
        thread_id: nil,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        dispatch_parallel(
          *inputs.map do |input|
            {agent: agent, input: input, config: config, thread_id: thread_id}
          end,
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          inherit_knowledge: inherit_knowledge
        )
      end

      def fan_out_async(
        agent:,
        inputs:,
        config: {},
        thread_id: nil,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        dispatch_parallel_async(
          *inputs.map do |input|
            {agent: agent, input: input, config: config, thread_id: thread_id}
          end,
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          inherit_knowledge: inherit_knowledge
        )
      end

      def subagent(
        agent_class,
        input,
        config: nil,
        thread_id: nil,
        inherit_knowledge: true
      )
        if Phronomy::Runtime.in_event_loop_context?
          raise Phronomy::EventLoopReentrancyError,
            "subagent cannot block the EventLoop; use the async Agent API"
        end
        build_subagent(
          agent_class,
          inherit_knowledge: inherit_knowledge
        ).invoke_async(
          input,
          config: config || {},
          thread_id: thread_id
        ).wait_result
      end

      private

      def prepare_tool_class(tool_class, invocation: nil)
        prepared = super
        return prepared unless self.class._subagent_tool_classes.include?(tool_class)

        subagent_name = tool_class.tool_name.delete_prefix("dispatch_to_")
        registration = self.class.registered_subagents.find do |name, _|
          name.to_s == subagent_name
        end&.last
        inherits_knowledge = registration ? registration.fetch(:inherit_knowledge, true) : true

        captured_context = {}
        captured_context[:knowledge] = active_knowledge_snapshot if inherits_knowledge
        if invocation
          captured_context.merge!(
            thread_id: invocation.thread_id,
            config: invocation.config,
            invocation_context: invocation.config[:invocation_context]
          )
        end
        captured_context.freeze

        effective_name = prepared.new.name
        Class.new(prepared) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            self._orchestrator_context = captured_context
            super(args, **kwargs)
          end
          define_method(:call_async) do |args, **kwargs|
            self._orchestrator_context = captured_context
            super(args, **kwargs)
          end
        end
      end

      def active_knowledge_snapshot
        journal_projection.context_records.filter_map do |record|
          next unless record.kind == :knowledge

          {
            content: persistence.contents.fetch_text(record.content_ref),
            metadata: (record.metadata || {}).dup.freeze
          }.freeze
        end.freeze
      end

      def build_subagent(agent_class, inherit_knowledge: true, knowledge_snapshot: nil)
        agent = agent_class.new
        return agent unless inherit_knowledge

        snapshot = knowledge_snapshot || active_knowledge_snapshot
        snapshot.each do |entry|
          agent.add_knowledge(
            entry.fetch(:content),
            metadata: entry.fetch(:metadata, {})
          )
        end
        agent
      end

      def validate_parallel_options!(tasks, max_concurrency, on_error)
        unless %i[raise skip].include?(on_error)
          raise ArgumentError, "unknown on_error: #{on_error.inspect}"
        end
        if max_concurrency && !(max_concurrency.is_a?(Integer) && max_concurrency.positive?)
          raise ArgumentError, "max_concurrency must be a positive Integer"
        end
        tasks.each do |task|
          raise ArgumentError, "fan-out task must be a Hash" unless task.is_a?(Hash)
          raise ArgumentError, "fan-out task requires :agent" unless task[:agent]
          raise ArgumentError, "fan-out task requires :input" unless task.key?(:input)
        end
      end

      def build_fan_out_children(
        tasks,
        cancellation_token:,
        invocation_context:,
        inherit_knowledge:
      )
        inheritance_flags = tasks.map { |task| task.fetch(:inherit_knowledge, inherit_knowledge) }
        knowledge_snapshot = active_knowledge_snapshot if inheritance_flags.any?

        tasks.each_with_index.map do |task, index|
          task_config = task.fetch(:config, {}).dup
          if cancellation_token && !task_config[:cancellation_token]
            task_config[:cancellation_token] = cancellation_token
          end
          if invocation_context && !task_config[:invocation_context]
            task_config[:invocation_context] = invocation_context.merge(
              parent_task_id: invocation_context.task_id
            )
          end

          child_agent = build_subagent(
            task.fetch(:agent),
            inherit_knowledge: inheritance_flags[index],
            knowledge_snapshot: knowledge_snapshot
          )

          FanOutInvocation::Child.new(
            index: index,
            agent: child_agent,
            input: task.fetch(:input),
            config: task_config,
            thread_id: task[:thread_id] || invocation_context&.thread_id
          )
        end
      end
    end
  end
end
