# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Base class for orchestrator agents that coordinate multiple subagents.
    class Orchestrator < Agent::Base
      agent_definition id: "orchestrator", version: 1

      # @api public
      def self.subagent(name, agent_class, on_error: :raise)
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

            result = agent_class.new.invoke_async(
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
        invocation_context: nil
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
          invocation_context: invocation_context
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
        invocation_context: nil
      )
        dispatch_parallel(
          *inputs.map do |input|
            {agent: agent, input: input, config: config, thread_id: thread_id}
          end,
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context
        )
      end

      # Programmatic single-subagent dispatch. Context propagation is explicit:
      # pass invocation_context in +config+ when this call must inherit a parent.
      # @api public
      def subagent(agent_class, input, config: nil, thread_id: nil)
        agent_class.new.invoke_async(
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

        captured_context = if invocation
          {
            thread_id: invocation.thread_id,
            config: invocation.config,
            invocation_context: invocation.config[:invocation_context]
          }.freeze
        else
          {}.freeze
        end
        effective_name = prepared.new.name
        Class.new(prepared) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            self._orchestrator_context = captured_context
            super(args, **kwargs)
          end
        end
      end

      def bounded_map(
        tasks,
        max_concurrency:,
        on_error:,
        timeout: nil,
        cancellation_token: nil,
        invocation_context: nil
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

            results[index] = task[:agent].new.invoke_async(
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
