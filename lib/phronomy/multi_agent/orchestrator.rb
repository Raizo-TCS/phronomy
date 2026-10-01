# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Base class for orchestrator agents that coordinate multiple subagents.
    class Orchestrator < Agent::Base
      agent_definition id: "orchestrator", version: 1

      ParallelChild = Data.define(:index, :agent, :input, :config)
      private_constant :ParallelChild

      attr_reader :coordination_store

      def self.create(coordination_store: nil, **options, &block)
        new(coordination_store: coordination_store, **options, &block)
      end

      def self.load(agent_id, persistence:, coordination_store:, **options, &block)
        participant = DurableSubagentCoordinator.new(agent_class: self, persistence: coordination_store)
        super(agent_id, persistence: persistence, execution_wiring: {phronomy_execution_participant: participant}, **options, &block)
      end

      def initialize(coordination_store: nil, execution_wiring: {}, **options, &block)
        @coordination_store = coordination_store || execution_wiring[:phronomy_execution_participant]&.persistence || Phronomy.configuration.multi_agent_store
        super(execution_wiring: execution_wiring, **options, &block)
        if @coordination_store && !@coordination_store.agent_store.equal?(persistence)
          raise Phronomy::ConfigurationError, "Orchestrator stores must share the same Agent store"
        end
        @participant = @coordination_store && DurableSubagentCoordinator.new(agent_class: self.class, persistence: @coordination_store)
      end

      # Current composition, never serialized in an execution record.
      def __invocation_config(config)
        if !self.class.registered_subagents.empty? && !@participant
          raise Phronomy::ConfigurationError, "Durable subagents require coordination_store:"
        end
        config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new,
          phronomy_execution_participant: @participant).compact
      end

      def self.subagent(name, agent_class, on_error: :raise, inherit_knowledge: true)
        # A subagent Tool is logically asynchronous: ToolInvocation starts the
        # child Agent and resumes when its completion TaskResult settles. It must not
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
            Phronomy::TaskResult.failed(error, name: "subagent-dispatch-failed")
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
                agent.add_knowledge(entry.content, metadata: entry.metadata)
              end
            end
            Phronomy::AsyncOperation.call(name: "subagent-tool-#{name}",
              on_error: ->(error) { raise error if on_error == :raise },
              transform: ->(result) { result[:output] }) do
              agent.invoke_async(input, config: task_config)
            end
          rescue => error
            Phronomy::AsyncOperation.capture(name: "subagent-tool-#{name}",
              on_error: ->(failure) { raise failure if on_error == :raise }) { raise error }
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
        if Phronomy::WaitPolicy.blocking_forbidden?
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
        children = build_fan_out_children(
          tasks,
          cancellation_token: nil,
          invocation_context: nil,
          inherit_knowledge: inherit_knowledge
        )
        Phronomy::Execution.run_async(children,
          timeout: timeout, cancellation_token: cancellation_token,
          invocation_context: invocation_context, max_concurrency: max_concurrency) do |child, execution|
          execution.start_child(
            invocation_context: child.config[:invocation_context],
            cancellation_token: child.config[:cancellation_token],
            parent_task_id: invocation_context&.task_id
          ) do |child_context, token|
            child.agent.invoke_async(child.input,
              config: child.config.merge(cancellation_token: token),
              invocation_context: child_context)
          end
        end.map do |outcomes|
          failure = outcomes.find { |outcome| outcome.status != :completed }
          raise failure.error if failure && on_error == :raise

          outcomes.map { |outcome| (outcome.status == :completed) ? outcome.value : nil }
        end
      end

      def subagent(
        agent_class,
        input,
        config: nil,
        inherit_knowledge: true
      )
        if Phronomy::WaitPolicy.blocking_forbidden?
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

      def active_knowledge_snapshot = knowledge_snapshot

      def build_subagent(agent_class, inherit_knowledge: true, knowledge_snapshot: nil)
        agent = agent_class.new
        return agent unless inherit_knowledge

        snapshot = knowledge_snapshot || active_knowledge_snapshot
        snapshot.each do |entry|
          agent.add_knowledge(
            entry.content,
            metadata: entry.metadata
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

          ParallelChild.new(
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
