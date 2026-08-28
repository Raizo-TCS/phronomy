# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    class ToolInvocation
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
        @config = config
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

        validated, schema_error = if @tool.respond_to?(:validate_and_coerce, true)
          @tool.send(:validate_and_coerce, @raw_arguments)
        else
          [@raw_arguments, nil]
        end

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
        pool = runtime.pool(
          :authorization,
          size: Phronomy.configuration.authorization_pool_size,
          queue_size: Phronomy.configuration.authorization_queue_size
        )
        timeout = @config.fetch(
          :authorization_timeout,
          Phronomy.configuration.authorization_timeout
        )
        operation = pool.submit(
          timeout: timeout,
          cancellation_token: @config[:cancellation_token],
          on_full: :raise
        ) { evaluator.send(:evaluate_authorization_command, command) }
        runtime.event_loop.supervise_agent_operation(@execution_id, operation)
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
          runtime.event_loop.supervise_agent_operation(@execution_id, operation)

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
        @tool&.respond_to?(:params_schema) ? @tool.params_schema : {}
      end

      def display_arguments
        redact_for_display(@arguments || @raw_arguments)
      end

      def display_facts
        redact_value(@facts, sensitive_argument_values)
      end

      private

      def authorization_command
        definition = @agent.class.agent_definition

        AuthorizationCommand.new(
          agent_id: @agent.agent_id.to_s.freeze,
          agent_definition_id: definition.fetch(:id).to_s.freeze,
          agent_definition_version: Integer(definition.fetch(:version)),
          execution_id: @execution_id,
          tool_name: @tool_name.to_s.freeze,
          tool_schema: self.class.send(:immutable_command_copy, tool_schema),
          tool_invocation_id: @id.to_s.freeze,
          tool_call_id: @tool_call_id&.to_s&.freeze,
          arguments: self.class.send(
            :immutable_command_copy,
            @arguments || {}
          ),
          approval_policy: self.class.send(
            :safe_behavior_handle, @approval_policy, "approval_policy"
          ),
          approval_facts_callable: self.class.send(
            :safe_behavior_handle, authorization_facts_callable, "approval_facts"
          ),
          approval_requirement: self.class.send(
            :safe_behavior_handle, authorization_requirement, "requires_approval"
          ),
          approval_context: self.class.send(
            :immutable_command_copy,
            @approval_context
          ),
          origin: @origin,
          metadata: self.class.send(:immutable_command_copy, @metadata)
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
        facts = evaluate_authorization_facts(command)
        request = request.with(facts: facts)
        default_decision = evaluate_default_authorization_decision(command, request)
        request = request.with(default_decision: default_decision)
        decision = command.approval_policy ? command.approval_policy.call(request) : default_decision
        decision = decision.to_sym if decision.respond_to?(:to_sym)

        unless ApprovalEvaluationRequest::VALID_DECISIONS.include?(decision)
          raise Phronomy::ConfigurationError,
            "tool_approval_policy must return :allow, :require_approval, or :reject " \
            "(got #{decision.inspect})"
        end

        reason = if decision == :require_approval
          (command.origin == :mcp) ?
            "MCP Tool execution requires approval" : "Tool execution requires approval"
        end
        AuthorizationOutcome.new(
          tool_invocation_id: command.tool_invocation_id,
          decision: decision,
          facts: facts,
          reason: reason
        )
      end
      private_class_method :evaluate_authorization_command

      def self.evaluate_authorization_facts(command)
        callable = command.approval_facts_callable
        return {} unless callable

        value = callable.call(command.arguments, command.approval_context)
        unless value.nil? || value.is_a?(Hash)
          raise Phronomy::ConfigurationError,
            "approval_facts must return a Hash or nil (got #{value.class})"
        end
        immutable_command_copy(value || {})
      end
      private_class_method :evaluate_authorization_facts

      def self.evaluate_default_authorization_decision(command, request)
        requirement = command.approval_requirement
        requirement = requirement.call(request) if requirement.respond_to?(:call)
        case requirement
        when true then :require_approval
        when false, nil then :allow
        else
          raise Phronomy::ConfigurationError,
            "requires_approval callable must return true or false (got #{requirement.inspect})"
        end
      end
      private_class_method :evaluate_default_authorization_decision

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

      def self.immutable_command_copy(value)
        if phronomy_managed_live_domain_object?(value)
          raise Phronomy::ConfigurationError,
            "authorization worker snapshot cannot contain Phronomy-managed live " \
            "domain object #{value.class}"
        end

        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[immutable_command_copy(key)] = immutable_command_copy(item)
          end.freeze
        when Array
          value.map { |item| immutable_command_copy(item) }.freeze
        when String
          value.dup.freeze
        else
          # Application-defined opaque objects are permitted by ACS-11 and remain
          # Application-owned. A stricter general value-type protocol is deferred.
          value
        end
      end
      private_class_method :immutable_command_copy

      def self.phronomy_managed_live_domain_object?(value)
        value.is_a?(Phronomy::Agent::Base) ||
          value.is_a?(Phronomy::Agent::AgentRoot) ||
          value.is_a?(Phronomy::Agent::AgentExecution) ||
          value.is_a?(Phronomy::Agent::AgentInvocation) ||
          value.is_a?(Phronomy::Agent::ToolInvocation) ||
          value.is_a?(Phronomy::Agent::JournalProjection) ||
          value.is_a?(Phronomy::Agent::ExecutionCoordinator) ||
          value.is_a?(Phronomy::Agent::Context::Capability::Base) ||
          value.is_a?(Phronomy::Workflow) ||
          value.is_a?(Phronomy::WorkflowRunner) ||
          value.is_a?(Phronomy::WorkflowContext) ||
          value.is_a?(Phronomy::Runtime) ||
          value.is_a?(Phronomy::Task) ||
          value.is_a?(Phronomy::EventLoop) ||
          value.is_a?(Phronomy::FSMSession) ||
          value.is_a?(Phronomy::FSMSession::EventSink) ||
          value.is_a?(Phronomy::Concurrency::CancellationToken) ||
          value.is_a?(Phronomy::Concurrency::OffloadPool)
      end
      private_class_method :phronomy_managed_live_domain_object?

      def self.safe_behavior_handle(value, name)
        return value if value.nil? || value == true || value == false
        if phronomy_managed_live_domain_object?(value)
          raise Phronomy::ConfigurationError,
            "#{name} must not be a Phronomy-managed live domain object (got #{value.class})"
        end
        value
      end
      private_class_method :safe_behavior_handle

      # Compatibility helpers for the existing private behavioral specs. These
      # evaluate a frozen operation command just like the worker path; they do not
      # reintroduce worker-side access to live mutable ToolInvocation state.
      def evaluate_authorization
        self.class.send(:evaluate_authorization_command, authorization_command)
      end

      def evaluate_facts
        self.class.send(:evaluate_authorization_facts, authorization_command)
      end

      def evaluate_default_decision(request)
        self.class.send(
          :evaluate_default_authorization_decision,
          authorization_command,
          request
        )
      end

      def build_request(facts:, default_decision:)
        self.class.send(
          :build_authorization_request,
          authorization_command,
          facts: facts,
          default_decision: default_decision
        )
      end

      def start_async_tool_operation(runtime)
        if uses_default_call_async?
          Phronomy::Agent::ToolExecutor.call_async(
            tool: @tool,
            args: @arguments,
            cancellation_token: @config[:cancellation_token],
            config: @config,
            runtime: runtime,
            on_full: :raise
          )
        else
          @tool.call_async(
            @arguments,
            cancellation_token: @config[:cancellation_token],
            config: @config
          )
        end
      end

      def uses_default_call_async?
        @tool.method(:call_async).owner ==
          Phronomy::Agent::Context::Capability::Base
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
            error.is_a?(Phronomy::TransportError) ||
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

      # Private compatibility helpers used by existing behavioral specs. Runtime
      # callbacks use only the pure class helpers above and captured semantic IDs.
      def execution_outcome(result, error)
        self.class.send(:build_execution_outcome, @id, result, error)
      end

      def authorization_failure_outcome(error)
        self.class.send(:authorization_failure_result, @id, error)
      end

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
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            result[immutable_copy(key)] = immutable_copy(item)
          end.freeze
        when Array
          value.map { |item| immutable_copy(item) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
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
