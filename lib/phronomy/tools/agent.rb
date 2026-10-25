# frozen_string_literal: true

module Phronomy
  module Tools
    # Wraps a Phronomy::Agent::Base subclass as a callable Tool.
    #
    # Agent-backed Tools are logically asynchronous rather than offloaded
    # synchronous operations. Their ToolInvocation starts the child Agent and then
    # returns to EventLoop immediately; the Tool completion handle settles when the
    # child Agent's physical work and release finish. An OffloadPool worker is
    # therefore never consumed merely to wait for another Agent.
    class Agent < Phronomy::Tool::Base
      execution_mode :cooperative
      description "Wraps a Phronomy::Agent as a Tool"
      param :input, type: :string, desc: "The input to forward to the wrapped Agent"

      # A private child's operation ended, but its safe release failed. The live
      # reference supports retrying unload_async without repeating business work.
      # This error and its child reference are process-local, not durable state.
      # @api public
      class CleanupError < Phronomy::ToolError
        attr_reader :child_agent, :agent_id, :result, :primary_error, :cleanup_error

        def initialize(child_agent:, result:, primary_error:, cleanup_error:)
          @child_agent = child_agent
          @agent_id = child_agent.agent_id
          @result = result
          @primary_error = primary_error
          @cleanup_error = cleanup_error
          super("Agent Tool cleanup failed for #{@agent_id.inspect}", code: "tool.agent_cleanup_failed")
        end
      end

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
            if Phronomy::WaitPolicy.blocking_forbidden?
              raise Phronomy::EventLoopReentrancyError,
                "Agent Tool execute cannot block EventLoop; use call_async"
            end
            execute_async(input: input, cancellation_token: cancellation_token).wait_result
          end

          # Internal asynchronous execution protocol used by Agent#call_async.
          # C04 decides whether release is safe; C13 composes completion. The
          # concrete Tool supplies only creation, output and cleanup policies.
          klass.define_method(:execute_async) do |input:, cancellation_token: nil, config: {}|
            unless config.nil? || config.is_a?(Hash)
              raise ArgumentError, "Agent Tool config must be a Hash"
            end
            task_config = (config || {}).dup
            if cancellation_token && !task_config[:cancellation_token]
              task_config[:cancellation_token] = cancellation_token
            end

            persistence = Phronomy::Agent::DefaultPersistence.build
            agent = agent_class.create(persistence: persistence)
            Phronomy::AsyncOperation.finalize(name: "agent-tool-#{name}-release",
              cleanup: -> { agent.unload_async },
              on_cleanup_error: ->(value, primary, cleanup) { child_cleanup_failed(agent, value, primary, cleanup) }) do
              Phronomy::AsyncOperation.call(name: "agent-tool-#{name}-invoke",
                transform: ->(result) { result[:output].to_s }) do
                agent.invoke_async(input, config: task_config)
              end
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

      def child_cleanup_failed(agent, result, primary_error, cleanup_error)
        failure = CleanupError.new(child_agent: agent, result: result,
          primary_error: primary_error, cleanup_error: cleanup_error)
        # Always report cleanup failures: an outer observer may already have
        # cancelled its handle, so returning an error alone is not sufficient.
        report_child_cleanup_failure(failure)
        raise failure, cause: primary_error || cleanup_error
      end

      def report_child_cleanup_failure(failure)
        details = {"agent_id" => failure.agent_id, "code" => failure.code,
                   "cleanup_error" => Phronomy::Error.diagnostic(failure.cleanup_error)}
        details["primary_error"] = Phronomy::Error.diagnostic(failure.primary_error) if failure.primary_error
        message = "[Phronomy] Agent Tool cleanup failed: #{details.inspect}"
        logger = Phronomy::RuntimeSettings.current.logger
        logger ? logger.error(message) : warn(message)
      rescue
        # Diagnostics cannot change the combined error or repeat the operation.
        nil
      end

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
