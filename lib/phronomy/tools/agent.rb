# frozen_string_literal: true

module Phronomy
  module Tools
    # Wraps a Phronomy::Agent::Base subclass as a callable Tool.
    #
    # Agent-backed Tools are logically asynchronous rather than offloaded
    # synchronous operations. Their ToolInvocation starts the child Agent and then
    # returns to EventLoop immediately; the Tool completion handle settles when the
    # child Agent FSMSession finishes. An OffloadPool worker is therefore never
    # consumed merely to wait for another Agent.
    class Agent < Phronomy::Agent::Context::Capability::Base
      execution_mode :cooperative
      description "Wraps a Phronomy::Agent as a Tool"
      param :input, type: :string, desc: "The input to forward to the wrapped Agent"

      class << self
        def from_agent(agent_class, tool_name: nil, description: nil)
          raise ArgumentError, "agent_class must be a Class" unless agent_class.is_a?(Class)
          unless agent_class <= Phronomy::Agent::Base
            raise ArgumentError,
              "agent_class must inherit from Phronomy::Agent::Base"
          end

          # Fail at Tool definition time rather than on the first Tool call.
          agent_class.agent_definition

          klass = Class.new(self)
          effective_name = tool_name || derive_name(agent_class)
          effective_desc = description || "Delegates to #{agent_class.name || "an agent"}"

          klass.tool_name(effective_name)
          klass.description(effective_desc)

          # Preserve the synchronous Tool API for top-level callers. ToolInvocation
          # never uses this path for Agent-backed Tools; it calls #call_async.
          klass.define_method(:execute) do |input:, cancellation_token: nil|
            invoke_options = {}
            if cancellation_token
              invoke_options[:config] = {cancellation_token: cancellation_token}
            end
            result = Phronomy::Agent.run_once(
              definition: agent_class,
              input: input,
              **invoke_options
            )
            result[:output].to_s
          end

          # Internal asynchronous execution protocol used by Agent#call_async.
          # The child Agent owns its own FSMSession/EventLoop lifecycle; this
          # method only returns its completion handle and performs a short map.
          klass.define_method(:execute_async) do |input:, cancellation_token: nil, config: {}|
            persistence = Phronomy::Persistence::InMemory.new
            agent = agent_class.create(persistence: persistence)
            task_config = (config || {}).dup
            if cancellation_token && !task_config[:cancellation_token]
              task_config[:cancellation_token] = cancellation_token
            end

            agent.invoke_async(input, config: task_config).map do |result|
              result[:output].to_s
            end
          end
          klass.send(:private, :execute_async)
          klass
        end

        private

        def derive_name(agent_class)
          return "agent_tool" unless agent_class.name

          agent_class.name
            .split("::").last
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
            .gsub(/([a-z\\d])([A-Z])/, '\\1_\\2')
            .downcase
            .sub(/_agent$/, "")
            .sub(/_tool$/, "")
        end
      end

      # Agent-backed Tools have an asynchronous implementation that does not use
      # ToolExecutor/OffloadPool. Validation and Tool error policy still match
      # Capability::Base#call.
      def call_async(
        args,
        cancellation_token: nil,
        config: {}
      )
        cancellation_token&.raise_if_cancelled!
        validated_args, schema_error = send(:validate_and_coerce, args)

        if schema_error
          return schema_error_task(schema_error)
        end

        source = execute_async(
          **(validated_args || {}),
          cancellation_token: cancellation_token,
          config: config || {}
        )
        unless source.respond_to?(:on_complete)
          raise Phronomy::ToolError,
            "#{self.class.name} asynchronous execution must return a completion handle"
        end

        result_task = Phronomy::Task.deferred(name: "agent-tool-#{name}")
        source.on_complete do |result, error|
          if error
            settle_async_error(result_task, error)
            next
          end

          begin
            result_task.complete(send(:truncate_result_if_needed, result))
          rescue => result_error
            settle_async_error(result_task, result_error)
          end
        end
        result_task
      rescue Phronomy::ToolError, Phronomy::CancellationError => error
        failed_task(error)
      rescue => error
        result_task = Phronomy::Task.deferred(name: "agent-tool-#{name}")
        settle_async_error(result_task, error)
        result_task
      end

      private

      # Subclasses created by .from_agent and Orchestrator override this method.
      # It deliberately remains private so it is not part of the public Tool API.
      def execute_async(input:, cancellation_token: nil, config: {})
        task = Phronomy::Task.deferred(name: "agent-tool-#{name}-fallback")
        begin
          task.complete(execute(input: input, cancellation_token: cancellation_token))
        rescue => error
          task.fail(error)
        end
        task
      end

      def schema_error_task(schema_error)
        task = Phronomy::Task.deferred(name: "agent-tool-#{name}-schema")
        if self.class.on_schema_error == :raise
          task.fail(Phronomy::ToolError.new(
            "#{self.class.name} schema error: #{schema_error}"
          ))
        else
          task.complete("Schema validation failed: #{schema_error}")
        end
        task
      end

      def failed_task(error)
        Phronomy::Task.deferred(name: "agent-tool-#{name}-failed").tap do |task|
          task.fail(error)
        end
      end

      def settle_async_error(task, error)
        if error.is_a?(Phronomy::ToolError) || error.is_a?(Phronomy::CancellationError)
          task.fail(error)
          return task
        end

        if self.class.on_error == :suppress
          message = "[Phronomy] Tool #{self.class.name} suppressed error: " \
            "#{error.class}: #{error.message}"
          if Phronomy.configuration.logger
            Phronomy.configuration.logger.warn(message)
          else
            warn message
          end
          task.complete("Tool error suppressed: #{error.message}")
        else
          wrapped = Phronomy::ToolError.new(
            "#{self.class.name} execution failed: #{error.message}"
          )
          wrapped.set_backtrace(error.backtrace)
          task.fail(wrapped)
        end
        task
      end
    end
  end
end
