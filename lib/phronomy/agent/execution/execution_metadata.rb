# frozen_string_literal: true

module Phronomy
  module Agent
    # Durable metadata shared by ordinary execution and recovery.
    # Keys and version values retain their existing stored representation.
    # @api private
    module ExecutionMetadata
      CONTRACT_VERSION = 1
      RECOVERY_METADATA_KEY = "recovery"
      TOOL_BATCH_METADATA_KEY = "recovery_tool_batch"
      PENDING_LLM_ID_KEY = "pending_llm_call_id"
      PENDING_LLM_STARTED_AT_KEY = "pending_llm_started_at"
      INVOCATION_MODE_KEY = "invocation_mode"
      CONTRACT_VERSION_KEY = "recovery_contract_version"

      module_function

      def build_tool_batch_snapshot(invocation)
        Array(invocation.tool_invocations).map do |child|
          entry = {
            "tool_invocation_id" => child.id.to_s,
            "tool_call_id" => child.tool_call_id&.to_s,
            "tool_name" => child.tool_name.to_s,
            "llm_call_id" => invocation.tool_batch_llm_call_id&.to_s,
            "raw_arguments" => serializable_value(child.raw_arguments || {}),
            "arguments" => serializable_value(child.raw_arguments || {}),
            "status" => child.status.to_s
          }
          if child.execution_completed?
            entry["result"] = serializable_value(child.result)
          end
          entry.compact
        end.freeze
      end

      def with_values(execution, values)
        execution.with(
          execution_revision: execution.execution_revision,
          metadata: execution.metadata.merge(values)
        )
      end

      # Retain the diagnostic used by existing snapshot writers. Conversion
      # prepares the tree; canonical JSON validation belongs to persistence.
      def serializable_value(value)
        Phronomy::Values::Serializable.convert(value,
          unsupported_message: "Recovery value is not canonically serializable")
      end
      private_class_method :serializable_value
    end
  end
end
