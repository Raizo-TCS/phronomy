# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Base class for orchestrator agents that coordinate multiple subagents.
    class Orchestrator < Agent::Base
      agent_definition id: "orchestrator", version: 1

      # @api public
      def self.subagent(name, agent_class, on_error: :raise, inherit_knowledge: true)
        tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
          tool_name "dispatch_to_#{name}"
          description "Dispatch work to the #{name} subagent (#{agent_class.name})"
          param :input, type: :string, desc: "The task or question for the subagent"

          attr_writer :_orchestrator_context

          define_method(:execute) do |input:|
            ctx = @_orchestrator_context || {}
            parent_ic = ctx[:invocation_context]
            task_config = ctx[:config] || {}

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

            result = agent.invoke_async(
              input,
              thread_id: ctx[:thread_id] || parent_ic&.thread_id,
              config: task_config
            ).wait_result
            result[:output]
          rescue
            raise if on_error == :raise
            nil
          end
        end

        @_subagent_tool_classes = (@_subagent_tool_classes || []) + [tool_class]
        @tools = (@tools || []) + [tool_class]
        @tool_aliases ||= {}
        registered_subagents[name] = {agent_class: agent_class, on_error: on_error}
      end

      def self._subagent_tool_classes
        @_subagent_tool_classes || []
      end

      # @api public
      def self.registered_subagents
        @registered_subagents ||= {}
      end

      # @api public
      def dispatch_parallel(
        *tasks,
        max_concurrency: nil,
        on_error: :raise,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        unless %i[raise skip].include?(on_error)
          raise ArgumentError, "unknown on_error: #{on_error.inspect}"
        end
        if max_concurrency && !(max_concurrency.is_a?(Integer) && max_concurrency.positive?)
          raise ArgumentError, "max_concurrency must be a positive Integer"
        end

        bounded_map(
          tasks,
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          inherit_knowledge: inherit_knowledge,
          knowledge_snapshot: active_knowledge_snapshot
        )
      end

      # @api public
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

      # Programmatic single-subagent dispatch. Context propagation is explicit:
      # pass invocation_context in +config+ when this call must inherit a parent.
      # Active parent Knowledge is inherited by default; pass
      # +inherit_knowledge: false+ to create an isolated subagent.
      # @api public
      def subagent(
        agent_class,
        input,
        config: nil,
        thread_id: nil,
        inherit_knowledge: true
      )
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

      # Capture the current invocation directly while materializing Tool classes.
      # No legacy invoke_once/thread-local bridge is involved.
      def prepare_tool_class(tool_class, invocation: nil)
        prepared = super
        return prepared unless self.class._subagent_tool_classes.include?(tool_class)

        captured_context = {
          knowledge: active_knowledge_snapshot
        }
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

      def build_subagent(
        agent_class,
        inherit_knowledge: true,
        knowledge_snapshot: active_knowledge_snapshot
      )
        agent = agent_class.new
        return agent unless inherit_knowledge

        knowledge_snapshot.each do |entry|
          agent.add_knowledge(
            entry.fetch(:content),
            metadata: entry.fetch(:metadata, {})
          )
        end
        agent
      end

      def bounded_map(
        tasks,
        max_concurrency:,
        on_error:,
        knowledge_snapshot:,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil,
        inherit_knowledge: true
      )
        return [] if tasks.empty?

        results = Array.new(tasks.length)
        errors = Array.new(tasks.length)
        group = Phronomy::Runtime.instance.task_group(
          limit: max_concurrency || tasks.length
        )
        effective_ct = cancellation_token || invocation_context&.cancellation_token

        spawned = tasks.each_with_index.map do |task, index|
          group.spawn do
            task_config = task.fetch(:config, {})

            if effective_ct && !task_config[:cancellation_token]
              task_config = task_config.merge(cancellation_token: effective_ct)
            end

            if invocation_context && !task_config[:invocation_context]
              child_ic = invocation_context.merge(
                parent_task_id: invocation_context.task_id
              )
              task_config = task_config.merge(invocation_context: child_ic)
            end

            task_inherits_knowledge = task.fetch(
              :inherit_knowledge,
              inherit_knowledge
            )
            agent = build_subagent(
              task[:agent],
              inherit_knowledge: task_inherits_knowledge,
              knowledge_snapshot: knowledge_snapshot
            )

            results[index] = agent.invoke_async(
              task[:input],
              config: task_config,
              thread_id: task[:thread_id] || invocation_context&.thread_id
            ).wait_result
          rescue => error
            errors[index] = error unless on_error == :skip
          end
        end

        if timeout
          deadline = Phronomy::Concurrency::Deadline.in(timeout)
          spawned.each { |task| task.join([deadline.remaining_seconds, 0].max) }

          alive = spawned.select(&:alive?)
          unless alive.empty?
            group.cancel_all!
            raise Phronomy::TimeoutError,
              "dispatch_parallel timed out after #{timeout}s " \
              "(#{alive.length} of #{spawned.length} tasks still running)"
          end
        else
          spawned.each(&:wait_result)
        end

        first_error = errors.compact.first
        raise first_error if first_error

        results
      end
    end
  end
end
