# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Mutable state for one concrete ToolCall.
    #
    # The object is the Tool-side counterpart to {AgentInvocation}: it owns the
    # identity and state of one execution, while {FSMSession} owns transitions.
    #
    # @api private
    class ToolInvocation
      AuthorizationOutcome = Struct.new(
        :decision,
        :facts,
        :reason,
        :error,
        :cancelled,
        keyword_init: true
      )

      ExecutionOutcome = Struct.new(
        :result,
        :error,
        :cancelled,
        keyword_init: true
      )

      PREFLIGHT_SETTLED_STATES = %i[
        authorized awaiting_approval rejected failed cancelled completed
      ].freeze
      TERMINAL_STATES = %i[completed rejected failed cancelled].freeze

      attr_reader :id,
        :parent_agent_invocation_id,
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
        :session_id,
        :phase,
        :config,
        :approval_policy,
        :approval_context,
        :origin,
        :metadata

      def self.missing(parent_agent_invocation_id:, agent:, tool_call:, config: {})
        new(
          parent_agent_invocation_id: parent_agent_invocation_id,
          agent: agent,
          tool: nil,
          tool_call: tool_call,
          config: config
        ).tap do |invocation|
          invocation.send(:complete_missing_tool!)
        end
      end

      def initialize(
        parent_agent_invocation_id:,
        agent:,
        tool:,
        tool_call:,
        config:,
        approval_policy: nil,
        approval_context: {},
        id: SecureRandom.uuid
      )
        @id = id.to_s
        @parent_agent_invocation_id = parent_agent_invocation_id.to_s
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
        @metadata = immutable_copy(tool&.respond_to?(:approval_metadata) ? tool.approval_metadata : {})

        @arguments = nil
        @facts = {}.freeze
        @final_decision = nil
        @authorization_reason = nil
        @result = nil
        @error = nil
        @approval_consumed = false
        @status = :created
        @session_id = nil
        @phase = nil
      end

      def set_graph_metadata(thread_id: nil, phase: nil)
        @session_id = thread_id if thread_id
        @phase = phase
      end

      # Applies an asynchronous entry-action result on the EventLoop thread.
      # Called by FSMSession when a Task returns a non-context outcome object.
      def apply_fsm_action_result(outcome)
        case outcome
        when AuthorizationOutcome
          apply_authorization_outcome(outcome)
        when ExecutionOutcome
          apply_execution_outcome(outcome)
        end
        self
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
            @error = Phronomy::ToolError.new("#{@tool.class.name} schema error: #{schema_error}")
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
      rescue => e
        @error = e
        @status = :failed
        self
      end

      def authorization_task(runtime: Phronomy::Runtime.instance)
        pool = runtime.pool(
          :authorization,
          size: Phronomy.configuration.authorization_pool_size,
          queue_size: Phronomy.configuration.authorization_queue_size
        )
        timeout = @config.fetch(
          :authorization_timeout,
          Phronomy.configuration.authorization_timeout
        )
        cancellation_token = @config[:cancellation_token]
        pending = pool.submit(
          timeout: timeout,
          cancellation_token: cancellation_token,
          on_full: :raise
        ) do
          evaluate_authorization
        end

        task = Phronomy::Task.deferred(name: "tool-authorization:#{@tool_name}")
        pending.on_complete do |outcome, error|
          resolved = if error
            authorization_failure_outcome(error)
          else
            outcome
          end
          task.backend.unblock(resolved, nil)
          task.transition!(:completed, value: resolved)
        end
        task
      rescue => e
        task = Phronomy::Task.deferred(name: "tool-authorization:#{@tool_name}")
        outcome = authorization_failure_outcome(e)
        task.backend.unblock(outcome, nil)
        task.transition!(:completed, value: outcome)
        task
      end

      def execution_task(runtime: Phronomy::Runtime.instance)
        pending = Phronomy::Agent::ToolExecutor.call_invocation_async(
          tool_invocation: self,
          cancellation_token: @config[:cancellation_token],
          config: @config,
          runtime: runtime
        )
        task = Phronomy::Task.deferred(name: "tool-execution:#{@tool_name}")
        pending.on_complete do |result, error|
          outcome = if error
            ExecutionOutcome.new(
              error: error,
              cancelled: error.is_a?(Phronomy::CancellationError)
            )
          else
            ExecutionOutcome.new(result: result)
          end
          task.backend.unblock(outcome, nil)
          task.transition!(:completed, value: outcome)
        end
        task
      rescue => e
        task = Phronomy::Task.deferred(name: "tool-execution:#{@tool_name}")
        outcome = ExecutionOutcome.new(
          error: e,
          cancelled: e.is_a?(Phronomy::CancellationError)
        )
        task.backend.unblock(outcome, nil)
        task.transition!(:completed, value: outcome)
        task
      end

      def mark_awaiting_approval!
        @status = :awaiting_approval
        self
      end

      def mark_authorized!
        @approval_consumed = true if @status == :awaiting_approval
        @status = :authorized
        self
      end

      def mark_queued!
        @status = :queued
        self
      end

      def mark_running!
        @status = :running
        self
      end

      def mark_rejected!
        @final_decision = :reject
        @status = :rejected
        self
      end

      def mark_cancelled!
        @status = :cancelled
        self
      end

      def mark_framework_failed!(error)
        @error = error
        @status = :failed
        self
      end

      def validation_passed?
        @status == :valid
      end

      def validation_completed?
        @status == :completed
      end

      def failed?
        @status == :failed
      end

      def cancelled?
        @status == :cancelled
      end

      def rejected?
        @status == :rejected
      end

      def awaiting_approval?
        @status == :awaiting_approval
      end

      def authorized?
        @status == :authorized
      end

      def execution_completed?
        @status == :completed
      end

      def preflight_settled?
        PREFLIGHT_SETTLED_STATES.include?(@status)
      end

      def terminal?
        TERMINAL_STATES.include?(@status)
      end

      def dispatchable?
        return false unless @status == :queued

        @final_decision == :allow || @approval_consumed
      end

      def tool_schema
        @tool&.respond_to?(:params_schema) ? @tool.params_schema : {}
      end

      def display_arguments
        redact_for_display(@arguments || @raw_arguments)
      end

      def display_facts
        sensitive_values = sensitive_argument_values
        redact_value(@facts, sensitive_values)
      end

      private

      def evaluate_authorization
        request = build_request(facts: {}, default_decision: nil)
        facts = evaluate_facts
        request = request.with(facts: facts)
        default_decision = evaluate_default_decision(request)
        request = request.with(default_decision: default_decision)
        decision = @approval_policy ? @approval_policy.call(request) : default_decision
        decision = decision.to_sym if decision.respond_to?(:to_sym)

        unless ApprovalEvaluationRequest::VALID_DECISIONS.include?(decision)
          raise Phronomy::ConfigurationError,
            "tool_approval_policy must return :allow, :require_approval, or :reject " \
            "(got #{decision.inspect})"
        end

        reason = if decision == :require_approval
          (@origin == :mcp) ? "MCP Tool execution requires approval" : "Tool execution requires approval"
        end
        AuthorizationOutcome.new(decision: decision, facts: facts, reason: reason)
      end

      def evaluate_facts
        callable = @tool.class.respond_to?(:approval_facts) ? @tool.class.approval_facts : nil
        return {} unless callable

        value = callable.call(@arguments, @approval_context)
        unless value.nil? || value.is_a?(Hash)
          raise Phronomy::ConfigurationError,
            "approval_facts must return a Hash or nil (got #{value.class})"
        end
        immutable_copy(value || {})
      end

      def evaluate_default_decision(request)
        requirement = @tool.respond_to?(:requires_approval) ? @tool.requires_approval : false
        requirement = requirement.call(request) if requirement.respond_to?(:call)

        case requirement
        when true then :require_approval
        when false, nil then :allow
        else
          raise Phronomy::ConfigurationError,
            "requires_approval callable must return true or false (got #{requirement.inspect})"
        end
      end

      def build_request(facts:, default_decision:)
        ApprovalEvaluationRequest.new(
          agent: @agent,
          agent_invocation_id: @parent_agent_invocation_id,
          tool: @tool,
          tool_name: @tool_name,
          tool_schema: tool_schema,
          tool_invocation_id: @id,
          tool_call_id: @tool_call_id,
          arguments: @arguments,
          facts: facts,
          invocation_context: @approval_context,
          origin: @origin,
          metadata: @metadata,
          default_decision: default_decision
        )
      end

      def authorization_failure_outcome(error)
        if error.is_a?(Phronomy::TimeoutError) ||
            error.is_a?(Phronomy::TransportError) ||
            error.is_a?(Phronomy::BackpressureError)
          AuthorizationOutcome.new(
            decision: :require_approval,
            facts: {},
            reason: "Authorization could not be completed safely: #{error.message}"
          )
        elsif error.is_a?(Phronomy::CancellationError)
          AuthorizationOutcome.new(error: error, cancelled: true)
        else
          AuthorizationOutcome.new(error: error)
        end
      end

      def apply_authorization_outcome(outcome)
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
          value.each_with_object({}) { |(k, v), h| h[immutable_copy(k)] = immutable_copy(v) }.freeze
        when Array
          value.map { |v| immutable_copy(v) }.freeze
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
