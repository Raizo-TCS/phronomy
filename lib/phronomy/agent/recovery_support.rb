# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    module RecoverySupport
      CONTRACT_VERSION = 1
      RECOVERY_METADATA_KEY = "recovery"
      TOOL_BATCH_METADATA_KEY = "recovery_tool_batch"
      PENDING_LLM_ID_KEY = "pending_llm_call_id"
      PENDING_LLM_STARTED_AT_KEY = "pending_llm_started_at"
      INVOCATION_MODE_KEY = "invocation_mode"
      CONTRACT_VERSION_KEY = "recovery_contract_version"

      module_function

      def canonical_copy(value)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, canonical_copy(child)] }
        when Array
          value.map { |child| canonical_copy(child) }
        when Symbol
          value.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          if value.respond_to?(:to_h)
            canonical_copy(value.to_h)
          else
            raise ArgumentError,
              "Recovery value is not canonically serializable: #{value.class}"
          end
        end
      end

      def build_tool_batch_snapshot(invocation)
        Array(invocation.tool_invocations).map do |child|
          entry = {
            "tool_invocation_id" => child.id.to_s,
            "tool_call_id" => child.tool_call_id&.to_s,
            "tool_name" => child.tool_name.to_s,
            "llm_call_id" => invocation.tool_batch_llm_call_id&.to_s,
            "raw_arguments" => canonical_copy(child.raw_arguments || {}),
            "arguments" => canonical_copy(child.raw_arguments || {}),
            "status" => child.status.to_s
          }
          if child.execution_completed?
            entry["result"] = canonical_copy(child.result)
          end
          entry.compact
        end.freeze
      end

      def with_recovery_metadata(execution, values)
        execution.with(
          execution_revision: execution.execution_revision,
          metadata: execution.metadata.merge(values)
        )
      end

      def semantic_tool_id(execution_id:, llm_call_id:, tool_call_id:, tool_name:)
        source = [
          "tool_invocation",
          execution_id.to_s,
          llm_call_id.to_s,
          tool_call_id.to_s,
          tool_name.to_s
        ].join("\0")
        "tool_invocation-#{Digest::SHA256.hexdigest(source)}".freeze
      end

      def manifest_from_ref(agent, ref)
        raw = agent.persistence.contents.fetch_json(ref)
        Phronomy::Agent::LLMInputManifest.from_h(raw)
      end

      def materialize_projection(agent, manifest_ref)
        manifest = manifest_from_ref(agent, manifest_ref)
        projection = Phronomy::Agent::RubyLLMMaterializer.new(
          agent: agent,
          persistence: agent.persistence
        ).materialize(manifest: manifest, manifest_ref: manifest_ref)
        [manifest, projection]
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
          facts: Phronomy::Agent::Immutable.copy(
            descriptor.fetch(:facts, {})
          )
        }.freeze
      end

      def pending_llm_descriptor(execution)
        llm_call_id = execution.metadata[PENDING_LLM_ID_KEY]
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
        value = execution.metadata[RECOVERY_METADATA_KEY]
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
        Array(execution.metadata[TOOL_BATCH_METADATA_KEY]).filter_map do |entry|
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
            "tool_invocation_id" => semantic_tool_id(
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
          "version" => CONTRACT_VERSION,
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

      def latest_assistant_record(execution, llm_call_id: nil)
        Array(execution.working_records).reverse.find do |record|
          record.kind.to_sym == :assistant_message &&
            (llm_call_id.nil? || record.llm_call_id.to_s == llm_call_id.to_s)
        end
      end

      def build_invocation_for_suspended(agent, execution, projection, main_coordinator, listener)
        request = Phronomy::Agent::ToolApprovalRequest.from_h(
          execution.approval_request
        )
        assistant_record = latest_assistant_record(execution)
        unless assistant_record
          raise Phronomy::ExecutionRehydrationRequiredError,
            "suspended execution #{execution.execution_id} has no durable assistant Tool Call message"
        end

        materializer = Phronomy::Agent::RubyLLMMaterializer.new(
          agent: agent,
          persistence: agent.persistence
        )
        assistant_message = materializer.materialize_journal_record(
          assistant_record
        )

        config = {
          execution_id: execution.execution_id,
          phronomy_execution_coordinator: main_coordinator,
          phronomy_runtime_projection: projection
        }
        invocation = Phronomy::Agent::AgentInvocation.new(
          agent: agent,
          input: projection.ask_message,
          config: config,
          event_listener: listener,
          mode: (execution.metadata[INVOCATION_MODE_KEY] || "invoke").to_sym,
          execution_id: execution.execution_id
        )
        chat = agent.send(:build_chat, model_config: projection.model_config)
        agent.send(
          :_apply_runtime_projection_to_chat,
          chat,
          projection,
          invocation: invocation
        )
        if projection.ask_message
          chat.messages << RubyLLM::Message.new(
            role: :user,
            content: projection.ask_message
          )
        end
        chat.messages << assistant_message

        invocation.chat = chat
        invocation.user_message_sent = true
        invocation.approval_request = request
        invocation.instance_variable_set(
          :@tool_batch_llm_call_id,
          assistant_record.llm_call_id&.to_s
        )

        by_id = request.items.to_h do |item|
          [item.tool_invocation_id.to_s, item]
        end
        snapshots = Array(execution.metadata[TOOL_BATCH_METADATA_KEY])
        if snapshots.empty?
          raise Phronomy::ExecutionRehydrationRequiredError,
            "suspended execution #{execution.execution_id} predates the durable Tool batch snapshot"
        end

        calls_by_id = if assistant_message.tool_calls.respond_to?(:values)
          assistant_message.tool_calls.values.to_h do |call|
            [call.id.to_s, call]
          end
        else
          Array(assistant_message.tool_calls).to_h do |call|
            [call.id.to_s, call]
          end
        end

        children = snapshots.map do |snapshot|
          entry = snapshot.to_h { |key, value| [key.to_s, value] }
          call = calls_by_id.fetch(entry.fetch("tool_call_id").to_s) do
            raise Phronomy::ExecutionRehydrationRequiredError,
              "Tool Call #{entry.fetch("tool_call_id")} is missing from the durable assistant message"
          end
          tool = chat.tools[entry.fetch("tool_name").to_sym]
          child = if tool
            Phronomy::Agent::ToolInvocation.new(
              execution_id: execution.execution_id,
              agent: agent,
              tool: tool,
              tool_call: call,
              config: config,
              id: entry.fetch("tool_invocation_id")
            )
          else
            Phronomy::Agent::ToolInvocation.missing(
              execution_id: execution.execution_id,
              agent: agent,
              tool_call: call,
              config: config,
              id: entry.fetch("tool_invocation_id")
            )
          end
          restore_tool_snapshot!(child, entry, by_id)
          child
        end
        invocation.tool_invocations = children
        invocation
      end

      def restore_tool_snapshot!(child, entry, approval_items)
        status = entry.fetch("status").to_sym
        case status
        when :awaiting_approval
          child.validate! unless child.terminal?
          child.instance_variable_set(:@final_decision, :require_approval)
          child.mark_awaiting_approval!
        when :authorized
          child.validate! unless child.terminal?
          child.instance_variable_set(:@final_decision, :allow)
          child.mark_authorized!
        when :completed
          child.instance_variable_set(:@result, entry["result"])
          child.instance_variable_set(:@status, :completed)
        when :rejected
          child.mark_rejected!
        when :failed
          child.mark_framework_failed!(
            Phronomy::ToolError.new("durably restored Tool preflight failure")
          )
        when :cancelled
          child.mark_cancelled!
        else
          raise Phronomy::ExecutionRehydrationRequiredError,
            "unsupported durable Tool snapshot state: #{status.inspect}"
        end

        item = approval_items[child.id.to_s]
        if item
          child.instance_variable_set(:@facts, Phronomy::Agent::Immutable.copy(item.facts))
          child.instance_variable_set(:@authorization_reason, item.reason)
        end
        child
      end

      def build_chat_for_recovery(agent, execution, projection, main_coordinator, listener)
        config = {
          execution_id: execution.execution_id,
          phronomy_execution_coordinator: main_coordinator,
          phronomy_runtime_projection: projection
        }
        invocation = Phronomy::Agent::AgentInvocation.new(
          agent: agent,
          input: projection.ask_message,
          config: config,
          event_listener: listener,
          mode: (execution.metadata[INVOCATION_MODE_KEY] || "invoke").to_sym,
          execution_id: execution.execution_id
        )
        chat = agent.send(:build_chat, model_config: projection.model_config)
        agent.send(
          :_apply_runtime_projection_to_chat,
          chat,
          projection,
          invocation: invocation
        )
        if projection.ask_message
          chat.messages << RubyLLM::Message.new(
            role: :user,
            content: projection.ask_message
          )
        end

        materializer = Phronomy::Agent::RubyLLMMaterializer.new(
          agent: agent,
          persistence: agent.persistence
        )
        Array(execution.working_records).each do |record|
          next unless %i[assistant_message tool_message].include?(record.kind.to_sym)

          chat.messages << materializer.materialize_journal_record(record)
        end

        invocation.chat = chat
        invocation.user_message_sent = true
        invocation
      end

      def provider_output_and_usage(agent, execution)
        assistant = latest_assistant_record(execution)
        payload = assistant ? agent.persistence.contents.fetch_json(assistant.content_ref) : {}
        output = payload["content"]

        call = execution.llm_calls.last
        usage_hash = if call&.usage_ref
          agent.persistence.contents.fetch_json(call.usage_ref)
        else
          {}
        end
        usage = Phronomy::TokenUsage.new(
          input: usage_hash["input"] || usage_hash[:input],
          output: usage_hash["output"] || usage_hash[:output],
          cached: usage_hash["cached"] || usage_hash[:cached],
          cache_creation: usage_hash["cache_creation"] || usage_hash[:cache_creation]
        )
        [output, usage]
      end
    end
  end
end
