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
    class Agent < Phronomy::Tool::Base
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
            persistence = Phronomy::Agent::DefaultPersistence.build
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
      # Tool::Base#call.
      def call_async(
        args,
        cancellation_token: nil,
        config: {}
      )
        call_async_operation(args, cancellation_token: cancellation_token,
          operation_name: "agent-tool-#{name}") do |validated_args|
          execute_async(**validated_args, cancellation_token: cancellation_token, config: config || {})
        end
      end

      private

      # Subclasses created by .from_agent override this method.
      # It deliberately remains private so it is not part of the public Tool API.
      def execute_async(input:, cancellation_token: nil, config: {})
        Phronomy::AsyncOperation.capture(name: "agent-tool-#{name}-fallback") do
          execute(input: input, cancellation_token: cancellation_token)
        end
      end

      # Agent recovery is an Agent operation outcome, not a generic Tool error.
      def async_error_value(error)
        raise error if error.is_a?(Phronomy::ExecutionRehydrationRequiredError)

        super
      end
    end
  end
end
