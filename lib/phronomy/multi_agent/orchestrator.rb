# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Base class for orchestrator agents that coordinate multiple subagents.
    class Orchestrator < Agent::Base
      agent_definition id: "orchestrator", version: 1

      # Own one live cancellation token shared with this invocation's static
      # children, including when Recovery reconstructs the invocation.
      # @api private
      def __invocation_config(config)
        config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new)
      end

      # Resumes retained static child coordination with current class wiring.
      # @api public
      def resume(execution_id, config: {})
        if Phronomy::Runtime.in_event_loop_context?
          raise Phronomy::EventLoopReentrancyError, "Orchestrator#resume cannot block EventLoop"
        end
        execution = persistence.executions.load(execution_id)
        raise Phronomy::Persistence::ConflictError, "Parent execution owner mismatch" unless execution.agent_id == agent_id
        input = persistence.contents.fetch_text(execution.metadata.fetch("current_input_ref"))
        result = Phronomy::Agent::ExactExecution.start(agent: self, execution_id: execution_id, input: input, config: config).wait_result
        raise Phronomy::Agent::RecoverySupport.error_from_failure(result[:error]) if result[:error]
        result
      end

      def self.subagent(name, agent_class, on_error: :raise, inherit_knowledge: true)
        # A subagent Tool is logically asynchronous: ToolInvocation starts the
        # child Agent and resumes when its completion Task settles. It must not
        # occupy an OffloadPool worker while waiting for the child.
        tool_class = Class.new(Phronomy::Tools::Agent) do
          def self.__framework_owned_operation? = true
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

          # Enter exact child reconciliation even when the parent token is
          # cancelled: an already admitted child must be settled, not forgotten.
          define_method(:call_async) do |args, cancellation_token: nil, config: {}|
            if @_orchestrator_context&.fetch(:parent, nil) && config[:phronomy_tool_invocation_id]
              validated, schema_error = send(:validate_and_coerce, args)
              raise Phronomy::ToolError, schema_error if schema_error
              execute_async(**validated, cancellation_token: cancellation_token, config: config)
            else
              super(args, cancellation_token: cancellation_token, config: config)
            end
          rescue => error
            Phronomy::Task.deferred(name: "subagent-dispatch-failed").tap { |task| task.fail(error) }
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

            parent = ctx[:parent]
            if parent && task_config[:phronomy_tool_invocation_id]
              return DurableSubagentCoordinator.start(parent: parent,
                tool_invocation_id: task_config.fetch(:phronomy_tool_invocation_id),
                parent_execution_id: task_config.fetch(:execution_id), config: task_config)
            end
            agent = agent_class.new
            if inherit_knowledge
              Array(ctx[:knowledge]).each do |entry|
                agent.add_knowledge(entry.fetch(:content), metadata: entry.fetch(:metadata, {}))
              end
            end
            source = agent.invoke_async(input, config: task_config)
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
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        dispatch_parallel(
          *inputs.map do |input|
            {agent: agent, input: input, config: config}
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
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        dispatch_parallel_async(
          *inputs.map do |input|
            {agent: agent, input: input, config: config}
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
          config: config || {}
        ).wait_result
      end

      # @api private
      def __framework_tool_replayable?(name)
        self.class.registered_subagents.keys.any? { |key| "dispatch_to_#{key}" == name.to_s }
      end

      # Reserve child identity/input/knowledge in the parent's existing Agent transaction.
      # @api private
      def __prepare_coordination_record(execution, tx:)
        DurableSubagentCoordinator.prepare(self, execution, tx: tx)
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

        captured_context = {parent: self}
        # Invocation-owned Tools inherit the durable child slot's knowledge,
        # captured by the existing preparation transaction off EventLoop.
        captured_context[:knowledge] = active_knowledge_snapshot if inherits_knowledge && !invocation
        if invocation
          captured_context[:config] = invocation.config
          captured_context[:invocation_context] = invocation.config[:invocation_context]
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
          if task.key?(:thread_id) || task.key?("thread_id")
            raise ArgumentError,
              "fan-out task generic thread_id was removed; " \
              "use purpose-specific domain identifiers or application tracing metadata"
          end
          _reject_removed_generic_identity_keys!(task.fetch(:config, {}))
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
            config: task_config
          )
        end
      end
    end
  end
end
