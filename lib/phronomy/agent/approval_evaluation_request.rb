# frozen_string_literal: true

module Phronomy
  module Agent
    # Value-oriented input passed to Tool approval policy callables.
    #
    # This object intentionally contains the internal, validated arguments used
    # for policy evaluation. It carries Agent identity metadata and Tool
    # description data only; it never exposes live Agent or Tool objects.
    #
    # Hash, Array, and String values are recursively copied/frozen. Other
    # application-owned opaque values remain application-owned; complete
    # value-type enforcement for those objects is outside ACS-11.
    #
    # This object must not be exposed directly to Application UI.
    # Use {ToolApprovalRequest} for notifications.
    #
    # @api public
    class ApprovalEvaluationRequest
      attr_reader :agent_id,
        :agent_definition_id,
        :agent_definition_version,
        :execution_id,
        :tool_name,
        :tool_schema,
        :tool_invocation_id,
        :tool_call_id,
        :arguments,
        :facts,
        :invocation_context,
        :origin,
        :metadata,
        :default_decision

      VALID_DECISIONS = %i[allow require_approval reject].freeze

      def initialize(
        agent_id:,
        agent_definition_id:,
        agent_definition_version:,
        execution_id:,
        tool_name:,
        tool_schema:,
        tool_invocation_id:,
        tool_call_id:,
        arguments:,
        facts: {},
        invocation_context: {},
        origin: :local,
        metadata: {},
        default_decision: nil
      )
        if agent_id.nil? || agent_id.to_s.empty?
          raise ArgumentError, "ApprovalEvaluationRequest requires agent_id"
        end
        if agent_definition_id.nil? || agent_definition_id.to_s.empty?
          raise ArgumentError,
            "ApprovalEvaluationRequest requires agent_definition_id"
        end
        if execution_id.nil? || execution_id.to_s.empty?
          raise ArgumentError, "ApprovalEvaluationRequest requires execution_id"
        end

        @agent_id = agent_id.to_s.freeze
        @agent_definition_id = agent_definition_id.to_s.freeze
        @agent_definition_version = Integer(agent_definition_version)
        @execution_id = execution_id.to_s.freeze
        @tool_name = tool_name.to_s.freeze
        @tool_schema = immutable_copy(tool_schema)
        @tool_invocation_id = tool_invocation_id.to_s.freeze
        @tool_call_id = tool_call_id&.to_s&.freeze
        @arguments = immutable_copy(arguments)
        @facts = immutable_copy(facts || {})
        @invocation_context = immutable_copy(invocation_context || {})
        @origin = origin.to_sym
        @metadata = immutable_copy(metadata || {})
        @default_decision = default_decision&.to_sym
        freeze
      end

      # Returns a new request with selected fields replaced.
      # @api private
      def with(facts: @facts, default_decision: @default_decision)
        self.class.new(
          agent_id: @agent_id,
          agent_definition_id: @agent_definition_id,
          agent_definition_version: @agent_definition_version,
          execution_id: @execution_id,
          tool_name: @tool_name,
          tool_schema: @tool_schema,
          tool_invocation_id: @tool_invocation_id,
          tool_call_id: @tool_call_id,
          arguments: @arguments,
          facts: facts,
          invocation_context: @invocation_context,
          origin: @origin,
          metadata: @metadata,
          default_decision: default_decision
        )
      end

      private

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
    end
  end
end
