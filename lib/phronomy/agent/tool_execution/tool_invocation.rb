# frozen_string_literal: true

require_relative "../../execution/concurrency/worker_input_restricted"

require "digest"
require "securerandom"

module Phronomy
  module Agent
    class ToolInvocation
      include Phronomy::Concurrency::WorkerInputRestricted

      AuthorizationOutcome = Data.define(
        :tool_invocation_id, :decision, :facts, :reason, :error, :cancelled
      ) do
        def initialize(
          tool_invocation_id: nil, decision: nil, facts: nil, reason: nil,
          error: nil, cancelled: false
        )
          super(
            tool_invocation_id: tool_invocation_id&.to_s&.freeze,
            decision: decision,
            facts: facts,
            reason: reason,
            error: error,
            cancelled: !!cancelled
          )
        end
      end

      ExecutionOutcome = Data.define(:tool_invocation_id, :result, :error, :cancelled) do
        def initialize(tool_invocation_id: nil, result: nil, error: nil, cancelled: false)
          super(
            tool_invocation_id: tool_invocation_id&.to_s&.freeze,
            result: result,
            error: error,
            cancelled: !!cancelled
          )
        end
      end

      # Operation input captured on EventLoop. Framework-owned container/String
      # value fields are immutable snapshots; callables are explicitly classified
      # Application-owned behavior handles. No Phronomy-managed live domain object
      # crosses this worker boundary as command/request data.
      AuthorizationCommand = Data.define(
        :agent_id, :agent_definition_id, :agent_definition_version,
        :execution_id, :tool_name, :tool_schema,
        :tool_invocation_id, :tool_call_id, :arguments,
        :approval_policy, :approval_facts_callable, :approval_requirement,
        :approval_context, :origin, :metadata
      )

      private_constant :AuthorizationCommand

      PREFLIGHT_SETTLED_STATES = %i[
        authorized awaiting_approval rejected failed cancelled completed
      ].freeze
      TERMINAL_STATES = %i[completed rejected failed cancelled].freeze

      attr_reader :id,
        :execution_id,
        :agent,
        :tool,
        :tool_name,
        :tool_call_id,
        :raw_arguments,
        :arguments,
        :facts,
        :final_decision,
        :authorization_reason,
        :result,
        :error,
        :status,
        :phase,
        :config,
        :approval_policy,
        :approval_context,
        :origin,
        :metadata

      # Stable identity used both before dispatch and when rebuilding facts.
      # This does not construct, authorize, or execute a Tool invocation.
      # @api private
      def self.semantic_id(execution_id:, llm_call_id:, tool_call_id:, tool_name:)
        source = [
          "tool_invocation",
          execution_id.to_s,
          llm_call_id.to_s,
          tool_call_id.to_s,
          tool_name.to_s
        ].join("\0")
        "tool_invocation-#{Digest::SHA256.hexdigest(source)}".freeze
      end

      def self.missing(
        execution_id:,
        agent:,
        tool_call:,
        config: {},
        id: SecureRandom.uuid
      )
        new(
          execution_id: execution_id,
          agent: agent,
          tool: nil,
          tool_call: tool_call,
          config: config,
          id: id
        ).tap { |invocation| invocation.send(:complete_missing_tool!) }
      end

      def initialize(
        execution_id:,
        agent:,
        tool:,
        tool_call:,
        config:,
        approval_policy: nil,
        approval_context: {},
        id: SecureRandom.uuid
      )
        if execution_id.nil? || execution_id.to_s.empty?
          raise ArgumentError, "ToolInvocation requires execution_id"
        end

        @id = id.to_s
        @execution_id = execution_id.to_s.freeze
        @agent = agent
        @tool = tool
        @tool_name = tool_call.name.to_s
        @tool_call_id = tool_call.respond_to?(:id) ? tool_call.id : nil
        raw_arguments = tool_call.respond_to?(:arguments) ? (tool_call.arguments || {}) : {}
        @raw_arguments = immutable_copy(raw_arguments)
        @config = config.dup.freeze
        @approval_policy = approval_policy
        @approval_context = immutable_copy(approval_context || {})
        @origin = tool&.respond_to?(:tool_origin) ? tool.tool_origin.to_sym : :local
        @metadata = immutable_copy(
          tool&.respond_to?(:approval_metadata) ? tool.approval_metadata : {}
        )
        @arguments = nil
        @facts = {}.freeze
        @final_decision = nil
        @authorization_reason = nil
        @result = nil
        @error = nil
        @approval_consumed = false
        @status = :created
        @phase = nil
      end

      def set_graph_metadata(phase: nil)
        @phase = phase
      end

      # Restores a newly constructed invocation from materialized saved facts.
      # Recovery owns snapshot decoding and identity matching. This operation
      # owns state application; it neither dispatches nor reevaluates approval.
      # @api private
      def restore_state!(status:, result: nil, approval_item: nil)
        restore_saved_state!(status, result)
        restore_approval_evidence!(approval_item)
        self
      end

      def handle_fsm_event(event)
        case event.type
        when :authorization_completed
          outcome = event.payload
          if outcome.is_a?(Exception)
            outcome = AuthorizationOutcome.new(tool_invocation_id: @id, error: outcome)
          end
          return :consume unless authoritative_tool_outcome?(outcome)

          apply_authorization_outcome(outcome)
          true
        when :execution_completed
          outcome = event.payload
          if outcome.is_a?(Exception)
            outcome = ExecutionOutcome.new(
              tool_invocation_id: @id,
              error: outcome,
              cancelled: outcome.is_a?(Phronomy::CancellationError)
            )
          end
          return :consume unless authoritative_tool_outcome?(outcome)

          apply_execution_outcome(outcome)
          true
        else
          false
        end
      end

      def validate!
        return self if terminal?

        validated, schema_error = @tool.validate_arguments(@raw_arguments)

        if schema_error
          if @tool.class.respond_to?(:on_schema_error) && @tool.class.on_schema_error == :raise
            @error = Phronomy::ToolError.new(
              "#{@tool.class.name} schema error: #{schema_error}"
            )
            @status = :failed
          else
            @result = "Schema validation failed: #{schema_error}"
            @status = :completed
          end
          return self
        end

        @arguments = immutable_copy(validated || {})
        @status = :valid
        self
      rescue => error
        @error = error
        @status = :failed
        self
      end

      def start_authorization(runtime: Phronomy::Runtime.instance, &callback)
        raise ArgumentError, "start_authorization requires a callback" unless callback

        command = authorization_command
        evaluator = self.class
        tool_invocation_id = @id.to_s.freeze
        timeout = @config.fetch(
          :authorization_timeout,
          Phronomy.configuration.authorization_timeout
        )
        operation = Phronomy::Execution.submit(
          runtime: runtime, pool_name: :authorization,
          size: Phronomy.configuration.authorization_pool_size,
          queue_size: Phronomy.configuration.authorization_queue_size,
          timeout: timeout,
          cancellation_token: @config[:cancellation_token],
          on_full: :raise
        ) { evaluator.send(:evaluate_authorization_command, command) }
        Phronomy::Agent::ExecutionRegistry.for(runtime.event_loop).supervise_agent_operation(@execution_id, operation)
        operation.on_complete do |outcome, error|
          callback.call(
            error ? evaluator.send(:authorization_failure_result, tool_invocation_id, error) : outcome
          )
        end
        self
      rescue => error
        callback.call(
          self.class.send(:authorization_failure_result, @id.to_s, error)
        )
        self
      end

      def start_execution(runtime: Phronomy::Runtime.instance, &callback)
        raise ArgumentError, "start_execution requires a callback" unless callback
        unless dispatchable?
          callback.call(ExecutionOutcome.new(
            tool_invocation_id: @id,
            error: Phronomy::ToolError.new(
              "ToolInvocation #{@id} is not authorized for dispatch"
            )
          ))
          return self
        end

        trace_handle = nil
        case @tool.class.execution_mode
        when :cooperative, :offloaded
          trace_handle = Phronomy::Tracing::Automatic.start(
            "tool.execute",
            input: @arguments || @raw_arguments,
            agent_id: @agent.agent_id,
            execution_id: @execution_id,
            tool_invocation_id: @id,
            tool_call_id: @tool_call_id,
            tool_name: @tool_name,
            **@agent.send(:_build_caller_meta, @config)
          )
          operation = start_async_tool_operation(runtime)
          unless operation.respond_to?(:on_complete)
            raise Phronomy::ToolError,
              "Tool #{@tool.class.name}#call_async must return a completion handle"
          end
          Phronomy::Agent::ExecutionRegistry.for(runtime.event_loop).supervise_agent_operation(@execution_id, operation)

          evaluator = self.class
          tool_invocation_id = @id.to_s.freeze
          operation.on_complete do |result, error|
            Phronomy::Tracing::Automatic.finish(
              trace_handle,
              output: result,
              error: error
            )
            callback.call(
              evaluator.send(:build_execution_outcome, tool_invocation_id, result, error)
            )
          end
        else
          callback.call(ExecutionOutcome.new(
            tool_invocation_id: @id,
            error: Phronomy::ConfigurationError.new(
              "unknown Tool execution_mode: #{@tool.class.execution_mode.inspect}"
            )
          ))
        end
        self
      rescue => error
        Phronomy::Tracing::Automatic.finish(trace_handle, error: error)
        callback.call(
          self.class.send(:build_execution_outcome, @id.to_s, nil, error)
        )
        self
      end

      def mark_awaiting_approval! = (@status = :awaiting_approval
                                     self)

      def mark_authorized!
        @approval_consumed = true if @status == :awaiting_approval
        @status = :authorized
        self
      end

      def mark_queued! = (@status = :queued
                          self)

      def mark_running! = (@status = :running
                           self)

      def mark_rejected! = (@final_decision = :reject
                            @status = :rejected
                            self)

      def mark_cancelled! = (@status = :cancelled
                             self)

      def mark_framework_failed!(error) = (@error = error
                                           @status = :failed
                                           self)

      def validation_passed? = @status == :valid
      def validation_completed? = @status == :completed
      def failed? = @status == :failed
      def cancelled? = @status == :cancelled
      def rejected? = @status == :rejected
      def awaiting_approval? = @status == :awaiting_approval
      def authorized? = @status == :authorized
      def execution_completed? = @status == :completed
      def preflight_settled? = PREFLIGHT_SETTLED_STATES.include?(@status)
      def terminal? = TERMINAL_STATES.include?(@status)

      def dispatchable?
        @status == :queued && (@final_decision == :allow || @approval_consumed)
      end

      def tool_schema
        @tool&.respond_to?(:parameters_schema) ? @tool.parameters_schema : {}
      end

      def display_arguments
        redact_for_display(@arguments || @raw_arguments)
      end

      def display_facts
        redact_value(@facts, sensitive_argument_values)
      end

      private

      def restore_saved_state!(status, result)
        case status
        when :awaiting_approval
          validate! unless terminal?
          @final_decision = :require_approval
          mark_awaiting_approval!
        when :authorized
          validate! unless terminal?
          @final_decision = :allow
          mark_authorized!
        when :completed
          @result = result
          @status = :completed
        when :rejected
          mark_rejected!
        when :failed
          mark_framework_failed!(
            Phronomy::ToolError.new("durably restored Tool preflight failure")
          )
        when :cancelled
          mark_cancelled!
        else
          raise Phronomy::ExecutionRehydrationRequiredError,
            "unsupported durable Tool snapshot state: #{status.inspect}"
        end
      end

      def restore_approval_evidence!(item)
        return unless item

        @facts = immutable_copy(item.facts)
        @authorization_reason = item.reason
      end

      def authorization_command
        definition = @agent.class.agent_definition

        AuthorizationCommand.new(
          agent_id: @agent.agent_id.to_s.freeze,
          agent_definition_id: definition.fetch(:id).to_s.freeze,
          agent_definition_version: Integer(definition.fetch(:version)),
          execution_id: @execution_id,
          tool_name: @tool_name.to_s.freeze,
          tool_schema: Phronomy::Tool::Authorization.snapshot(tool_schema),
          tool_invocation_id: @id.to_s.freeze,
          tool_call_id: @tool_call_id&.to_s&.freeze,
          arguments: Phronomy::Tool::Authorization.snapshot(
            @arguments || {}
          ),
          approval_policy: Phronomy::Tool::Authorization.behavior(@approval_policy, "approval_policy"),
          approval_facts_callable: Phronomy::Tool::Authorization.behavior(authorization_facts_callable, "approval_facts"),
          approval_requirement: Phronomy::Tool::Authorization.behavior(authorization_requirement, "requires_approval"),
          approval_context: Phronomy::Tool::Authorization.snapshot(
            @approval_context
          ),
          origin: @origin,
          metadata: Phronomy::Tool::Authorization.snapshot(@metadata)
        )
      end

      def authorization_facts_callable
        return unless @tool&.class&.respond_to?(:approval_facts)

        @tool.class.approval_facts
      end

      def authorization_requirement
        return false unless @tool&.respond_to?(:requires_approval)

        @tool.requires_approval
      end

      def self.evaluate_authorization_command(command)
        request = build_authorization_request(command, facts: {}, default_decision: nil)
        decision = Phronomy::Tool::Authorization.call(
          request: request, arguments: command.arguments, context: command.approval_context,
          facts: command.approval_facts_callable, requirement: command.approval_requirement,
          policy: command.approval_policy
        )
        AuthorizationOutcome.new(
          tool_invocation_id: command.tool_invocation_id,
          decision: decision.decision, facts: decision.facts, reason: decision.reason
        )
      end
      private_class_method :evaluate_authorization_command

      def self.build_authorization_request(command, facts:, default_decision:)
        ApprovalEvaluationRequest.new(
          agent_id: command.agent_id,
          agent_definition_id: command.agent_definition_id,
          agent_definition_version: command.agent_definition_version,
          execution_id: command.execution_id,
          tool_name: command.tool_name,
          tool_schema: command.tool_schema,
          tool_invocation_id: command.tool_invocation_id,
          tool_call_id: command.tool_call_id,
          arguments: command.arguments,
          facts: facts,
          invocation_context: command.approval_context,
          origin: command.origin,
          metadata: command.metadata,
          default_decision: default_decision
        )
      end
      private_class_method :build_authorization_request

      def start_async_tool_operation(runtime)
        if uses_default_call_async?
          Phronomy::Tool::ToolExecutor.call_async(
            tool: @tool,
            args: @arguments,
            cancellation_token: @config[:cancellation_token],
            config: @config,
            runtime: runtime,
            on_full: :raise
          )
        else
          tool_config = @tool.class.respond_to?(:__framework_owned_operation?) ?
            @config.merge(phronomy_tool_invocation_id: @id, execution_id: @execution_id).freeze : @config
          @tool.call_async(
            @arguments,
            cancellation_token: @config[:cancellation_token],
            config: tool_config
          )
        end
      end

      def uses_default_call_async?
        @tool.method(:call_async).owner ==
          Phronomy::Tool::Base
      end

      def self.build_execution_outcome(tool_invocation_id, result, error)
        if error
          ExecutionOutcome.new(
            tool_invocation_id: tool_invocation_id,
            error: error,
            cancelled: error.is_a?(Phronomy::CancellationError)
          )
        else
          ExecutionOutcome.new(tool_invocation_id: tool_invocation_id, result: result)
        end
      end
      private_class_method :build_execution_outcome

      def self.authorization_failure_result(tool_invocation_id, error)
        if error.is_a?(Phronomy::TimeoutError) ||
            error.is_a?(Phronomy::LLMAdapter::TransportError) ||
            error.is_a?(Phronomy::BackpressureError)
          AuthorizationOutcome.new(
            tool_invocation_id: tool_invocation_id,
            decision: :require_approval,
            facts: {},
            reason: "Authorization could not be completed safely: #{error.message}"
          )
        elsif error.is_a?(Phronomy::CancellationError)
          AuthorizationOutcome.new(
            tool_invocation_id: tool_invocation_id, error: error, cancelled: true
          )
        else
          AuthorizationOutcome.new(tool_invocation_id: tool_invocation_id, error: error)
        end
      end
      private_class_method :authorization_failure_result

      def authoritative_tool_outcome?(outcome)
        outcome.respond_to?(:tool_invocation_id) &&
          outcome.tool_invocation_id.to_s == @id
      end

      def apply_authorization_outcome(outcome)
        unless outcome.is_a?(AuthorizationOutcome)
          raise Phronomy::Error, "Expected AuthorizationOutcome, got #{outcome.class}"
        end
        @facts = immutable_copy(outcome.facts || {})
        @authorization_reason = outcome.reason
        @error = outcome.error
        if outcome.cancelled
          @status = :cancelled
        elsif outcome.error
          @status = :failed
        else
          @final_decision = outcome.decision
          @status = case outcome.decision
          when :allow then :authorized
          when :require_approval then :awaiting_approval
          when :reject then :rejected
          end
        end
      end

      def apply_execution_outcome(outcome)
        unless outcome.is_a?(ExecutionOutcome)
          raise Phronomy::Error, "Expected ExecutionOutcome, got #{outcome.class}"
        end
        @result = outcome.result
        @error = outcome.error
        @status = if outcome.cancelled
          :cancelled
        elsif outcome.error
          :failed
        else
          :completed
        end
      end

      def complete_missing_tool!
        @result = "Tool not found: #{@tool_name}"
        @status = :completed
      end

      def immutable_copy(value)
        Phronomy::Values::Immutable.copy(value)
      end

      def redact_for_display(value)
        if @tool&.respond_to?(:redacted_args, true)
          immutable_copy(@tool.send(:redacted_args, value || {}))
        else
          immutable_copy(value || {})
        end
      end

      def sensitive_argument_values
        return [] unless @tool&.class&.respond_to?(:redact_params)
        normalized = (@arguments || @raw_arguments || {}).transform_keys(&:to_sym)
        @tool.class.redact_params.filter_map { |name| normalized[name] }
      end

      def redact_value(value, sensitive_values)
        return "[REDACTED]" if sensitive_values.any? { |sensitive| sensitive == value }

        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[key] = redact_value(item, sensitive_values)
          end.freeze
        when Array
          value.map { |item| redact_value(item, sensitive_values) }.freeze
        when String
          "[REDACTED]"
        else
          value
        end
      end
    end
  end
end
