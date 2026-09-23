# frozen_string_literal: true

module Phronomy
  module Agent
    module RecoverySupport
      module_function

      def canonical_copy(value)
        Phronomy::Values::Serializable.convert(value,
          unsupported_message: "Recovery value is not canonically serializable")
      end

      def tool_calls_from_outcome(outcome)
        Array(outcome.tool_calls)
      end

      def normalize_provider_outcome(value)
        return value if value.is_a?(Phronomy::Agent::ProviderCallOutcome)

        if value.is_a?(Hash)
          return Phronomy::Agent::ProviderCallOutcome.from_h(value)
        end

        captured = Phronomy::Agent::ProviderCallOutcome.capture(value)
        return captured if captured

        raise ArgumentError,
          "LLM Recovery :succeeded requires a Provider result or ProviderCallOutcome-compatible Hash"
      end

      def resolution_failure(error)
        {
          "class" => error.class.name.to_s,
          "message" => error.message.to_s
        }.freeze
      end

      def error_from_failure(failure)
        hash = failure.to_h { |key, value| [key.to_s, value] }
        Phronomy::Error.new(
          "#{hash.fetch("class", "Error")}: #{hash.fetch("message", "Recovery-resolved failure")}"
        )
      end

      def event_payload(execution, descriptor)
        {
          execution_id: execution.execution_id,
          execution_revision: execution.execution_revision,
          reason: descriptor.fetch(:reason),
          subject: Phronomy::Recovery.normalize_subject(
            descriptor.fetch(:subject)
          ),
          allowed_outcomes: Array(
            descriptor.fetch(:allowed_outcomes)
          ).map(&:to_sym).freeze,
          facts: Phronomy::Values::Immutable.copy(
            descriptor.fetch(:facts, {})
          )
        }.freeze
      end

      def pending_llm_descriptor(execution)
        llm_call_id = execution.metadata[ExecutionMetadata::PENDING_LLM_ID_KEY]
        return unless llm_call_id

        {
          reason: :outcome_unknown,
          subject: {
            type: :llm_call,
            llm_call_id: llm_call_id
          },
          allowed_outcomes: Phronomy::Recovery::OUTCOMES,
          facts: {
            manifest_ref: execution.metadata["manifest_ref"],
            call_sequence: execution.llm_calls.length + 1
          }.compact.freeze
        }.freeze
      end

      def recovery_hash(execution)
        value = execution.metadata[ExecutionMetadata::RECOVERY_METADATA_KEY]
        value.is_a?(Hash) ? value : nil
      end

      def current_tool_descriptor(execution)
        recovery = recovery_hash(execution)
        return unless recovery

        subjects = Array(recovery["subjects"] || recovery[:subjects])
        current = subjects.find do |entry|
          hash = entry.to_h { |key, value| [key.to_s, value] }
          hash.fetch("state", "unresolved") == "unresolved"
        end
        return unless current

        hash = current.to_h { |key, value| [key.to_s, value] }
        {
          reason: (recovery["reason"] || recovery[:reason] || "outcome_unknown").to_sym,
          subject: {
            type: :tool_invocation,
            tool_invocation_id: hash.fetch("tool_invocation_id")
          },
          allowed_outcomes: Array(
            recovery["allowed_outcomes"] ||
              recovery[:allowed_outcomes] ||
              Phronomy::Recovery::OUTCOMES
          ).map(&:to_sym),
          facts: {
            tool_call_id: hash["tool_call_id"],
            tool_name: hash["tool_name"],
            arguments: hash["arguments"],
            llm_call_id: hash["llm_call_id"]
          }.compact
        }.freeze
      end

      def pending_tool_subjects(execution)
        Array(execution.metadata[ExecutionMetadata::TOOL_BATCH_METADATA_KEY]).filter_map do |entry|
          hash = entry.to_h { |key, value| [key.to_s, value] }
          next unless %w[authorized awaiting_approval].include?(
            hash.fetch("status")
          )

          {
            "tool_invocation_id" => hash.fetch("tool_invocation_id"),
            "llm_call_id" => hash["llm_call_id"],
            "tool_call_id" => hash.fetch("tool_call_id"),
            "tool_name" => hash.fetch("tool_name"),
            "arguments" => canonical_copy(
              hash["arguments"] || hash["raw_arguments"] || {}
            ),
            "state" => "unresolved"
          }.compact.freeze
        end.freeze
      end

      def pending_tool_descriptor(execution)
        subjects = pending_tool_subjects(execution)
        return if subjects.empty?

        first = subjects.first
        {
          reason: :outcome_unknown,
          subject: {
            type: :tool_invocation,
            tool_invocation_id: first.fetch("tool_invocation_id")
          },
          allowed_outcomes: Phronomy::Recovery::OUTCOMES,
          facts: {
            tool_call_id: first["tool_call_id"],
            tool_name: first["tool_name"],
            arguments: first["arguments"],
            llm_call_id: first["llm_call_id"]
          }.compact
        }.freeze
      end

      def recovery_descriptor(execution)
        case execution.phase.to_sym
        when :calling_llm
          pending_llm_descriptor(execution)
        when :resuming
          approved = execution.approval_request &&
            (
              execution.approval_request["approved"] ||
              execution.approval_request[:approved]
            )
          approved ? pending_tool_descriptor(execution) : nil
        when :dispatching_tools
          pending_tool_descriptor(execution)
        when :recovery_tools
          current_tool_descriptor(execution)
        end
      end

      def build_tool_subjects(execution, llm_call_id, outcome)
        tool_calls_from_outcome(outcome).map do |call|
          call_hash = canonical_copy(call)
          tool_call_id = call_hash.fetch("id").to_s
          tool_name = call_hash.fetch("name").to_s
          {
            "tool_invocation_id" => ToolInvocation.semantic_id(
              execution_id: execution.execution_id,
              llm_call_id: llm_call_id,
              tool_call_id: tool_call_id,
              tool_name: tool_name
            ),
            "llm_call_id" => llm_call_id.to_s,
            "tool_call_id" => tool_call_id,
            "tool_name" => tool_name,
            "arguments" => canonical_copy(call_hash.fetch("arguments", {})),
            "state" => "unresolved"
          }.freeze
        end.freeze
      end

      def build_recovery_hash(subjects, reason: :outcome_unknown, allowed_outcomes: Phronomy::Recovery::OUTCOMES)
        {
          "version" => ExecutionMetadata::CONTRACT_VERSION,
          "reason" => reason.to_s,
          "allowed_outcomes" => Array(allowed_outcomes).map(&:to_s),
          "subjects" => Array(subjects).map { |entry| canonical_copy(entry) }
        }.freeze
      end

      def update_recovery_subject(recovery, tool_invocation_id:, state:, outcome:, result_ref: nil)
        copy = canonical_copy(recovery)
        copy["subjects"] = Array(copy.fetch("subjects")).map do |entry|
          next entry unless entry.fetch("tool_invocation_id").to_s == tool_invocation_id.to_s

          entry.merge(
            "state" => state.to_s,
            "outcome" => outcome.to_s,
            "result_ref" => result_ref
          ).compact
        end
        copy.freeze
      end

      def unresolved_subjects(recovery)
        Array(recovery.fetch("subjects")).select do |entry|
          entry.fetch("state", "unresolved") == "unresolved"
        end
      end
    end
  end
end
