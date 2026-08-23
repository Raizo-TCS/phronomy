# frozen_string_literal: true

require "securerandom"
require "time"

module Phronomy
  module Agent
    # Application-facing notification for one suspended ToolCall batch.
    #
    # The request contains display-safe values only. Internal policy input is
    # represented by {ApprovalEvaluationRequest} and is deliberately separate.
    #
    # @api public
    class ToolApprovalRequest
      # One ToolInvocation included in a batch approval request.
      # @api public
      class Item
        attr_reader :tool_invocation_id,
          :tool_call_id,
          :tool_name,
          :arguments,
          :facts,
          :reason,
          :origin,
          :metadata

        def initialize(
          tool_invocation_id:,
          tool_call_id:,
          tool_name:,
          arguments:,
          facts:,
          reason:,
          origin:,
          metadata:
        )
          @tool_invocation_id = tool_invocation_id.to_s.freeze
          @tool_call_id = tool_call_id&.to_s&.freeze
          @tool_name = tool_name.to_s.freeze
          @arguments = immutable_copy(arguments)
          @facts = immutable_copy(facts)
          @reason = reason&.to_s&.freeze
          @origin = origin.to_sym
          @metadata = immutable_copy(metadata)
          freeze
        end

        def to_h
          {
            tool_invocation_id: @tool_invocation_id,
            tool_call_id: @tool_call_id,
            tool_name: @tool_name,
            arguments: @arguments,
            facts: @facts,
            reason: @reason,
            origin: @origin,
            metadata: @metadata
          }
        end

        private

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
      end

      attr_reader :id, :execution_id, :items, :created_at

      def self.build(agent_invocation)
        pending = agent_invocation.tool_invocations.select(&:awaiting_approval?)
        new(
          execution_id: agent_invocation.execution_id,
          items: pending.map { |invocation| build_item(invocation) }
        )
      end

      def self.build_item(invocation)
        Item.new(
          tool_invocation_id: invocation.id,
          tool_call_id: invocation.tool_call_id,
          tool_name: invocation.tool_name,
          arguments: invocation.display_arguments,
          facts: invocation.display_facts,
          reason: invocation.authorization_reason,
          origin: invocation.origin,
          metadata: invocation.metadata
        )
      end
      private_class_method :build_item

      def initialize(execution_id:, items:, id: SecureRandom.uuid, created_at: Time.now.utc)
        raise ArgumentError, "ToolApprovalRequest requires at least one item" if items.empty?
        if execution_id.nil? || execution_id.to_s.empty?
          raise ArgumentError, "ToolApprovalRequest requires execution_id"
        end

        @id = id.to_s.freeze
        @execution_id = execution_id.to_s.freeze
        @items = items.dup.freeze
        @created_at = created_at
        freeze
      end

      def to_h
        {
          id: @id,
          execution_id: @execution_id,
          items: @items.map(&:to_h),
          created_at: @created_at.iso8601
        }
      end
    end
  end
end
