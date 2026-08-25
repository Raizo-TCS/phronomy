# frozen_string_literal: true

require "securerandom"
require "time"
require "digest"

module Phronomy
  module Agent
    # Zeitwerk file constant for acs15_recovery.rb. Implementation components
    # below remain private and are composed into existing runtime classes.
    # @api private
    module Acs15Recovery
      VERSION = 1
    end

    # Private helpers for ACS-15 durable Recovery.
    # @api private
    module ACS15RecoverySupport
      CONTRACT_VERSION = 1
      RECOVERY_METADATA_KEY = "recovery"
      TOOL_BATCH_METADATA_KEY = "recovery_tool_batch"
      PENDING_LLM_ID_KEY = "pending_llm_call_id"
      PENDING_LLM_STARTED_AT_KEY = "pending_llm_started_at"
      INVOCATION_MODE_KEY = "invocation_mode"
      CONTRACT_VERSION_KEY = "recovery_contract_version"

      THREAD_INITIAL_MODE_KEY = :__phronomy_acs15_initial_mode

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

      def resuming_tool_subjects(execution)
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

      def resuming_tool_descriptor(execution)
        subjects = resuming_tool_subjects(execution)
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
          approved ? resuming_tool_descriptor(execution) : nil
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
            "suspended execution #{execution.execution_id} predates the ACS-15 durable Tool batch snapshot"
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

    # Exact v1 Manifest decoder required by restart hydration.
    class LLMInputManifest
      class Segment
        def self.from_h(hash)
          source = hash.to_h { |key, value| [key.to_s, value] }
          new(
            position: Integer(source.fetch("position")),
            category: source.fetch("category").to_sym,
            role: source["role"]&.to_sym,
            content_ref: source.fetch("content_ref").to_s,
            delivery: source.fetch("delivery").to_sym,
            tool_call_id: source["tool_call_id"]&.to_s,
            metadata: source["metadata"] || {}
          )
        end
      end

      def self.from_h(hash)
        source = hash.to_h { |key, value| [key.to_s, value] }
        version = Integer(source.fetch("version"))
        unless version == VERSION
          raise Phronomy::ConfigurationError,
            "unsupported LLMInputManifest version: #{version}; supported version is #{VERSION}"
        end

        new(
          version: version,
          call_sequence: source.fetch("call_sequence"),
          call_mode: source.fetch("call_mode"),
          assembly_policy_version: source.fetch("assembly_policy_version", 1),
          segments: Array(source.fetch("segments")).map { |segment| Segment.from_h(segment) },
          model_config_ref: source.fetch("model_config_ref"),
          tool_definitions_ref: source["tool_definitions_ref"],
          response_schema_ref: source["response_schema_ref"],
          ruby_llm_version: source["ruby_llm_version"],
          adapter_name: source["adapter_name"],
          adapter_version: source["adapter_version"]
        )
      end
    end

    ProviderCallOutcome.class_eval do
      def self.from_h(hash)
        source = hash.to_h { |key, value| [key.to_s, value] }
        new(
          role: source.fetch("role", "assistant"),
          content: source["content"],
          tool_calls: source.fetch("tool_calls", []),
          usage: source.fetch("usage", {}),
          metadata: source.fetch("metadata", {})
        )
      end

      def to_h
        {
          "role" => role&.to_s,
          "content" => content,
          "tool_calls" => tool_calls,
          "usage" => usage,
          "metadata" => metadata
        }.compact
      end
    end

    ToolApprovalRequest::Item.class_eval do
      def self.from_h(hash)
        values = hash.to_h { |key, value| [key.to_s, value] }
        new(
          tool_invocation_id: values.fetch("tool_invocation_id"),
          tool_call_id: values["tool_call_id"],
          tool_name: values.fetch("tool_name"),
          arguments: values.fetch("arguments", {}),
          facts: values.fetch("facts", {}),
          reason: values["reason"],
          origin: values.fetch("origin", "local"),
          metadata: values.fetch("metadata", {})
        )
      end
    end

    ToolApprovalRequest.class_eval do
      def self.from_h(hash)
        source = hash.to_h { |key, value| [key.to_s, value] }
        items = Array(source.fetch("items")).map { |item| Item.from_h(item) }
        new(
          execution_id: source.fetch("execution_id"),
          items: items,
          id: source.fetch("id"),
          created_at: Time.iso8601(source.fetch("created_at"))
        )
      end
    end

    class ToolInvocation
      class << self
        alias_method :__acs15_original_missing, :missing

        def missing(execution_id:, agent:, tool_call:, config: {}, id: SecureRandom.uuid)
          new(
            execution_id: execution_id,
            agent: agent,
            tool: nil,
            tool_call: tool_call,
            config: config,
            id: id
          ).tap { |invocation| invocation.send(:complete_missing_tool!) }
        end
      end
    end

    # Agent lifetime event-listener binding.
    # @api private
    module ACS15BaseLifecycle
      def initialize(*args, on_event: nil, **kwargs, &event_block)
        if on_event && event_block
          raise ArgumentError, "Provide either on_event: or a block, not both"
        end
        @_phronomy_event_listener = on_event || event_block
        super(*args, **kwargs)
      end

      private

      def _phronomy_event_listener
        @_phronomy_event_listener
      end
    end

    module ACS15BaseClassLifecycle
      def create(
        agent_id: SecureRandom.uuid,
        context: nil,
        knowledge: [],
        persistence: nil,
        metadata: {},
        on_event: nil,
        &event_block
      )
        new(
          agent_id: agent_id,
          context: context,
          knowledge: knowledge,
          persistence: persistence,
          metadata: metadata,
          on_event: on_event,
          &event_block
        )
      end

      def load(agent_id, persistence:, on_event: nil, &event_block)
        raise ArgumentError, "persistence is required" unless persistence
        if on_event && event_block
          raise ArgumentError, "Provide either on_event: or a block, not both"
        end

        key = agent_id.to_s
        raise ArgumentError, "agent_id must not be empty" if key.empty?

        listener_supplied = !on_event.nil? || !event_block.nil?
        runtime = Phronomy::Runtime.instance
        materialized = false

        agent = runtime.__load_agent(key, expected_class: self) do |owner_runtime|
          materialized = true
          instance = __construct_owned_agent(
            owner_runtime,
            key,
            agent_id: key,
            persistence: persistence,
            load_existing: true,
            on_event: on_event,
            &event_block
          )
          Phronomy::Agent::RecoveryCoordinator.new(instance).recover_on_load!
          instance
        end

        unless agent.persistence.equal?(persistence)
          raise Phronomy::ConfigurationError,
            "Agent #{key.inspect} is already live with a different Persistence instance"
        end

        if !materialized && listener_supplied
          raise Phronomy::ConfigurationError,
            "Agent #{key.inspect} is already live; load cannot add, replace, or re-bind on_event"
        end

        agent
      end
    end

    # Adds durable semantic IDs / Recovery snapshots without replacing the
    # existing ExecutionCoordinator orchestration.
    # @api private
    module ACS15ExecutionCoordinator
      private

      def perform_initial_preparation(operation)
        previous = Thread.current[
          ACS15RecoverySupport::THREAD_INITIAL_MODE_KEY
        ]
        Thread.current[
          ACS15RecoverySupport::THREAD_INITIAL_MODE_KEY
        ] = (
          operation.config[:phronomy_recovery_mode] || :invoke
        ).to_sym
        super
      ensure
        Thread.current[
          ACS15RecoverySupport::THREAD_INITIAL_MODE_KEY
        ] = previous
      end

      def admit_execution(raw_message, root:)
        if root.lifecycle_status == :closed
          raise Phronomy::Error,
            "agent is closed: #{@agent.agent_id}"
        end

        execution = next_root = nil
        mode = Thread.current[
          ACS15RecoverySupport::THREAD_INITIAL_MODE_KEY
        ] || :invoke
        pending_llm_call_id = SecureRandom.uuid.to_s.freeze
        pending_started_at = Time.now.utc.iso8601(6).freeze

        @agent.persistence.transaction do |tx|
          input_ref = tx.contents.put_text(raw_message)
          input_record = JournalRecord.new(
            agent_id: @agent.agent_id,
            kind: :input_received,
            channel: :external,
            role: :user,
            content_ref: input_ref,
            context_generation: root.transcript_generation,
            context_candidate: false
          )
          policy_descriptor = ContextPolicies::Default.new.descriptor
          execution = AgentExecution.start(
            agent_root: root,
            input_record: input_record,
            metadata: {
              "current_input_ref" => input_ref,
              "context_policy" => policy_descriptor.to_h,
              ACS15RecoverySupport::CONTRACT_VERSION_KEY =>
                ACS15RecoverySupport::CONTRACT_VERSION,
              ACS15RecoverySupport::INVOCATION_MODE_KEY => mode.to_s,
              ACS15RecoverySupport::PENDING_LLM_ID_KEY =>
                pending_llm_call_id,
              ACS15RecoverySupport::PENDING_LLM_STARTED_AT_KEY =>
                pending_started_at
            }.compact
          )
          input_record = JournalRecord.from_h(
            input_record.to_h.merge(
              "execution_id" => execution.execution_id
            )
          )
          execution = execution.with(
            execution_revision: 0,
            working_records: [input_record]
          )
          tx.executions.create_active(execution)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            lifecycle_status: :active
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end
        [execution, next_root]
      end

      def perform_followup_preparation(operation)
        pending_id = SecureRandom.uuid.to_s.freeze
        pending_started_at = Time.now.utc.iso8601(6).freeze
        staged_execution = ACS15RecoverySupport.with_recovery_metadata(
          operation.execution,
          ACS15RecoverySupport::PENDING_LLM_ID_KEY => pending_id,
          ACS15RecoverySupport::PENDING_LLM_STARTED_AT_KEY =>
            pending_started_at,
          ACS15RecoverySupport::CONTRACT_VERSION_KEY =>
            ACS15RecoverySupport::CONTRACT_VERSION
        )
        replacement = operation.class.new(
          **operation.to_h.merge(execution: staged_execution)
        )
        super(replacement)
      end

      def begin_terminal_commit_on_event_loop(
        state,
        result_task,
        invocation,
        source_error,
        fsm_session_id:
      )
        if invocation&.phase == :suspended
          snapshot = ACS15RecoverySupport.build_tool_batch_snapshot(
            invocation
          )
          staged_execution = ACS15RecoverySupport.with_recovery_metadata(
            state.execution,
            ACS15RecoverySupport::TOOL_BATCH_METADATA_KEY => snapshot
          )
          state = state.class.new(
            **state.to_h.merge(execution: staged_execution)
          )
        end

        super
      end

      def begin_resume_on_event_loop(request)
        event_loop = Phronomy::Runtime.instance.event_loop
        state = event_loop.agent_execution_state(request.execution_id)
        if state&.agent&.equal?(@agent) && state&.invocation
          @acs15_resume_snapshot_mutex ||= Mutex.new
          snapshot = ACS15RecoverySupport.build_tool_batch_snapshot(
            state.invocation
          )
          @acs15_resume_snapshot_mutex.synchronize do
            @acs15_resume_snapshots ||= {}
            @acs15_resume_snapshots[request.execution_id.to_s] =
              snapshot
          end
        end
        super
      end

      def perform_resume_commit(operation)
        snapshot = nil
        @acs15_resume_snapshot_mutex&.synchronize do
          snapshot = @acs15_resume_snapshots&.delete(
            operation.execution_id.to_s
          )
        end

        if snapshot
          staged_execution = ACS15RecoverySupport.with_recovery_metadata(
            operation.execution,
            ACS15RecoverySupport::TOOL_BATCH_METADATA_KEY => snapshot
          )
          operation = operation.class.new(
            **operation.to_h.merge(execution: staged_execution)
          )
        end
        super
      end
    end

    # Durable Recovery owner / resolver. Entity-specific rehydration remains here;
    # Phronomy::Recovery contains only shared semantic primitives.
    # @api private
    class RecoveryCoordinator
      class ResolutionOutcomeUnknownError < Phronomy::Error
        attr_reader :original_error, :intended_result

        def initialize(original_error, intended_result)
          @original_error = original_error
          @intended_result = intended_result
          super(
            "Recovery resolution Persistence outcome is unknown: " + "#{original_error.class}: #{original_error.message}"
          )
          set_backtrace(original_error.backtrace)
        end
      end
      private_constant :ResolutionOutcomeUnknownError

      InstallCommand = Data.define(
        :coordinator, :plan, :completion, :owner_token
      )
      ResolveCommand = Data.define(
        :coordinator, :execution_id, :expected_execution_revision,
        :subject, :outcome, :result, :failure, :completion
      )
      ResolveReady = Data.define(
        :coordinator, :request, :operation, :result, :error
      )
      ResolutionOperation = Data.define(
        :execution, :root, :subject, :outcome, :result, :failure
      )
      ResolutionResult = Data.define(
        :execution, :root, :continuation, :failure, :appended_records
      )
      RecoveryPlan = Data.define(
        :execution, :root, :manifest, :base_manifest,
        :projection, :classification
      )

      attr_reader :agent

      def initialize(agent)
        @agent = agent
      end

      def recover_on_load!
        active = agent.persistence.transaction do |tx|
          Array(tx.executions.list_active(agent.agent_id))
        end
        if active.length > 1
          raise Phronomy::Persistence::ConflictError,
            "multiple active AgentExecutions exist for #{agent.agent_id}"
        end
        return agent if active.empty?

        execution = active.first
        unless execution.agent_id.to_s == agent.agent_id.to_s
          raise Phronomy::Persistence::ConflictError,
            "active AgentExecution belongs to another Agent: #{execution.agent_id}"
        end

        plan = prepare_plan(execution)
        classification = plan.classification
        if classification.disposition ==
            Phronomy::Recovery::RESOLUTION_REQUIRED &&
            !agent.send(:_phronomy_event_listener)
          raise Phronomy::ConfigurationError,
            "Agent #{agent.agent_id.inspect} requires Recovery resolution; " \
            "load must register on_event"
        end
        if execution.status == :suspended &&
            !agent.send(:_phronomy_event_listener)
          raise Phronomy::ConfigurationError,
            "Agent #{agent.agent_id.inspect} has a pending approval; " \
            "load must register on_event"
        end

        completion = Phronomy::Task.deferred(
          name: "agent-recovery-load:#{execution.execution_id}"
        )
        command = InstallCommand.new(
          coordinator: self,
          plan: plan,
          completion: completion,
          owner_token: Object.new.freeze
        )
        unless post_control(command)
          completion.fail(
            Phronomy::RuntimeShutdownError.new(
              "EventLoop rejected Agent Recovery installation"
            )
          )
        end
        completion.wait_result
        agent
      end

      def resolve(
        execution_id,
        expected_execution_revision:,
        subject:,
        outcome:,
        result: Phronomy::Recovery::MISSING,
        error: Phronomy::Recovery::MISSING
      )
        agent.send(:__assert_live_agent!)
        normalized_outcome = Phronomy::Recovery.normalize_outcome(outcome)
        result_present = !result.equal?(Phronomy::Recovery::MISSING)
        error_present = !error.equal?(Phronomy::Recovery::MISSING)
        Phronomy::Recovery.validate_resolution_material!(
          outcome: normalized_outcome,
          result_present: result_present,
          error_present: error_present
        )

        normalized_subject =
          Phronomy::Recovery.normalize_subject(subject)
        canonical_result = if result_present
          if normalized_subject[:type] == :llm_call &&
              normalized_outcome == :succeeded
            ACS15RecoverySupport.normalize_provider_outcome(result).to_h
          else
            ACS15RecoverySupport.canonical_copy(result)
          end
        end
        failure = error_present ?
          ACS15RecoverySupport.resolution_failure(error) : nil

        completion = Phronomy::Task.deferred(
          name: "agent-recovery-resolve:#{execution_id}"
        )
        command = ResolveCommand.new(
          coordinator: self,
          execution_id: execution_id.to_s.freeze,
          expected_execution_revision:
            Integer(expected_execution_revision),
          subject: normalized_subject,
          outcome: normalized_outcome,
          result: canonical_result,
          failure: failure,
          completion: completion
        )
        unless post_control(command)
          completion.fail(
            Phronomy::RuntimeShutdownError.new(
              "EventLoop rejected Agent Recovery resolution"
            )
          )
        end
        completion
      rescue => caught
        completion ||= Phronomy::Task.deferred(
          name: "agent-recovery-resolve:#{execution_id}"
        )
        completion.fail(caught)
        completion
      end

      # @api private
      def deliver_on_event_loop(command)
        case command
        when InstallCommand
          install_on_event_loop(command)
        when ResolveCommand
          begin_resolve_on_event_loop(command)
        when ResolveReady
          apply_resolve_on_event_loop(command)
        else
          raise Phronomy::Error,
            "unknown Recovery control command: #{command.class}"
        end
      end

      private

      def prepare_plan(execution)
        root = agent.agent_root
        manifest_ref = execution.metadata["manifest_ref"]
        base_ref = execution.metadata["base_manifest_ref"] ||
          manifest_ref
        manifest = base_manifest = projection = nil
        if manifest_ref
          manifest, projection =
            ACS15RecoverySupport.materialize_projection(
              agent,
              manifest_ref
            )
          base_manifest = if base_ref.to_s == manifest_ref.to_s
            manifest
          else
            ACS15RecoverySupport.manifest_from_ref(agent, base_ref)
          end
        end

        classification = classify(execution)
        RecoveryPlan.new(
          execution: execution,
          root: root,
          manifest: manifest,
          base_manifest: base_manifest,
          projection: projection,
          classification: classification
        )
      end

      def classify(execution)
        if execution.status == :suspended &&
            execution.phase.to_sym == :approval
          return Phronomy::Recovery::Classification.new(
            disposition: Phronomy::Recovery::RESUMABLE,
            reason: :approval_wait,
            facts: {
              approval_request_id:
                execution.approval_request &&
                  (
                    execution.approval_request["id"] ||
                    execution.approval_request[:id]
                  )
            }.compact
          )
        end

        case execution.phase.to_sym
        when :recovery_provider_completed,
          :recovery_tools_completed,
          :recovery_resolved_failed
          return Phronomy::Recovery::Classification.new(
            disposition: Phronomy::Recovery::RESUMABLE,
            reason: execution.phase
          )
        when :resuming
          approved = execution.approval_request &&
            (
              execution.approval_request["approved"] ||
              execution.approval_request[:approved]
            )
          unless approved
            return Phronomy::Recovery::Classification.new(
              disposition: Phronomy::Recovery::RESUMABLE,
              reason: :approval_rejection_committed
            )
          end
        end

        descriptor = ACS15RecoverySupport.recovery_descriptor(
          execution
        )
        if descriptor
          return Phronomy::Recovery::Classification.new(
            disposition: Phronomy::Recovery::RESOLUTION_REQUIRED,
            reason: descriptor.fetch(:reason),
            subject: descriptor.fetch(:subject),
            allowed_outcomes:
              descriptor.fetch(:allowed_outcomes),
            facts: descriptor.fetch(:facts)
          )
        end

        raise Phronomy::ExecutionRehydrationRequiredError,
          "execution #{execution.execution_id} is not at an ACS-15 restart-safe durable continuation point " \
          "(status=#{execution.status.inspect}, phase=#{execution.phase.inspect})"
      end

      def install_on_event_loop(command)
        event_loop = Phronomy::Runtime.instance.event_loop
        plan = command.plan
        execution = plan.execution
        main = agent.send(:execution_coordinator)
        admitted = false
        bound = false
        installed = false

        event_loop.admit_agent_execution(
          agent.agent_id,
          owner_token: command.owner_token
        )
        admitted = true
        event_loop.bind_agent_execution_admission(
          agent.agent_id,
          owner_token: command.owner_token,
          execution_id: execution.execution_id
        )
        bound = true

        invocation = nil
        if execution.status == :suspended ||
            execution.phase.to_sym == :resuming
          invocation =
            ACS15RecoverySupport.build_invocation_for_suspended(
              agent,
              execution,
              plan.projection,
              main,
              agent.send(:_phronomy_event_listener)
            )
        elsif execution.phase.to_sym ==
            :recovery_tools_completed
          invocation =
            ACS15RecoverySupport.build_chat_for_recovery(
              agent,
              execution,
              plan.projection,
              main,
              agent.send(:_phronomy_event_listener)
            )
        elsif execution.phase.to_sym ==
            :recovery_provider_completed
          invocation =
            ACS15RecoverySupport.build_chat_for_recovery(
              agent,
              execution,
              plan.projection,
              main,
              agent.send(:_phronomy_event_listener)
            )
          output, usage =
            ACS15RecoverySupport.provider_output_and_usage(
              agent,
              execution
            )
          invocation.output = output
          invocation.usage = usage
        elsif execution.phase.to_sym ==
            :recovery_resolved_failed
          invocation = Phronomy::Agent::AgentInvocation.new(
            agent: agent,
            input: nil,
            config: {
              execution_id: execution.execution_id,
              phronomy_execution_coordinator: main
            },
            event_listener:
              agent.send(:_phronomy_event_listener),
            mode: (
              execution.metadata[
                ACS15RecoverySupport::INVOCATION_MODE_KEY
              ] || "invoke"
            ).to_sym,
            execution_id: execution.execution_id
          )
        end

        event_loop.install_agent_execution(
          execution_id: execution.execution_id,
          agent: agent,
          coordinator: main,
          execution: execution,
          runtime_projection: plan.projection,
          base_manifest: plan.base_manifest,
          invocation: invocation,
          fsm_session_id: nil
        )
        installed = true

        if execution.status == :suspended
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :suspended
          )
          request = invocation.approval_request
          callback_error = agent.send(
            :_deliver_stream_event,
            agent.send(:_phronomy_event_listener),
            StreamEvent.new(
              type: :approval_required,
              payload: {request: request}.freeze
            )
          )
          if callback_error
            raise agent.send(
              :_build_stream_callback_error,
              event_type: :approval_required,
              callback_error: callback_error,
              result: {
                execution_id: execution.execution_id,
                suspended: true
              }
            )
          end
          command.completion.complete(agent)
          return
        end

        case plan.classification.disposition
        when Phronomy::Recovery::RESOLUTION_REQUIRED
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :recovery_required
          )
          payload = ACS15RecoverySupport.event_payload(
            execution,
            {
              reason: plan.classification.reason,
              subject: plan.classification.subject,
              allowed_outcomes:
                plan.classification.allowed_outcomes,
              facts: plan.classification.facts
            }
          )
          callback_error = agent.send(
            :_deliver_stream_event,
            agent.send(:_phronomy_event_listener),
            StreamEvent.new(
              type: :recovery_resolution_required,
              payload: payload
            )
          )
          if callback_error
            raise agent.send(
              :_build_stream_callback_error,
              event_type: :recovery_resolution_required,
              callback_error: callback_error,
              result: payload
            )
          end
          command.completion.complete(agent)
        when Phronomy::Recovery::RESUMABLE
          continue_resumable_on_event_loop(
            execution,
            invocation,
            completion: command.completion
          )
        else
          raise Phronomy::Error,
            "unsupported Recovery installation disposition: #{plan.classification.disposition.inspect}"
        end
      rescue => caught
        if installed
          begin
            event_loop.release_agent_execution(
            execution.execution_id
          )
          rescue
            nil
          end
        end
        if admitted
          if bound
            begin
              event_loop.release_agent_execution_admission(
                agent.agent_id,
                execution_id: execution&.execution_id
              )
            rescue
              nil
            end
          else
            begin
              event_loop.release_agent_execution_admission(
                agent.agent_id,
                owner_token: command.owner_token
              )
            rescue
              nil
            end
          end
        end
        command.completion.fail(caught)
      end

      def continue_resumable_on_event_loop(
        execution,
        invocation,
        completion:
      )
        event_loop = Phronomy::Runtime.instance.event_loop
        main = agent.send(:execution_coordinator)

        case execution.phase.to_sym
        when :resuming
          approved = execution.approval_request &&
            (
              execution.approval_request["approved"] ||
              execution.approval_request[:approved]
            )
          if approved
            raise Phronomy::ExecutionRehydrationRequiredError,
              "approved resuming execution requires Tool outcome resolution"
          end
          internal_task = Phronomy::Task.deferred(
            name: "agent-recovery-auto:#{execution.execution_id}"
          )
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :executing
          )
          main.send(
            :start_resume_on_event_loop,
            execution.execution_id,
            internal_task,
            approved: false,
            config: {}
          )
          completion.complete(agent)
        when :recovery_tools_completed
          internal_task = Phronomy::Task.deferred(
            name: "agent-recovery-auto:#{execution.execution_id}"
          )
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :executing
          )
          start_followup_session(
            event_loop,
            main,
            execution,
            invocation,
            internal_task
          )
          completion.complete(agent)
        when :recovery_provider_completed
          AgentInvocationSessionBuilder.send(
            :output_filtering_action,
            agent,
            invocation
          )
          internal_task = Phronomy::Task.deferred(
            name: "agent-recovery-auto:#{execution.execution_id}"
          )
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: execution.execution_id,
            state: :executing
          )
          start_output_completion_session(
            event_loop,
            main,
            execution,
            invocation,
            internal_task
          )
          completion.complete(agent)
        when :recovery_resolved_failed
          failure = (
            execution.metadata[
              ACS15RecoverySupport::RECOVERY_METADATA_KEY
            ] || {}
          )["failure"] || {
            "class" => "Phronomy::Error",
            "message" => "Recovery-resolved failure"
          }
          error = ACS15RecoverySupport.error_from_failure(failure)
          internal_task = Phronomy::Task.deferred(
            name: "agent-recovery-auto:#{execution.execution_id}"
          )
          state = event_loop.agent_execution_state(
            execution.execution_id
          )
          main.send(
            :begin_terminal_commit_on_event_loop,
            state,
            internal_task,
            invocation,
            error,
            fsm_session_id: nil
          )
          completion.complete(agent)
        else
          raise Phronomy::ExecutionRehydrationRequiredError,
            "no automatic continuation for #{execution.phase.inspect}"
        end
      end

      def begin_resolve_on_event_loop(request)
        event_loop = Phronomy::Runtime.instance.event_loop
        state = event_loop.agent_execution_state(
          request.execution_id
        )
        unless state && state.agent.equal?(agent)
          request.completion.fail(
            Phronomy::ExecutionRehydrationRequiredError.new(
              "no live recovered execution #{request.execution_id}"
            )
          )
          return
        end

        current = state.execution
        unless current.execution_revision ==
            request.expected_execution_revision
          request.completion.fail(
            Phronomy::Persistence::ConflictError.new(
              "Recovery resolution revision conflict: expected " \
              "#{request.expected_execution_revision}, actual " \
              "#{current.execution_revision}"
            )
          )
          return
        end

        descriptor =
          ACS15RecoverySupport.recovery_descriptor(current)
        unless descriptor &&
            Phronomy::Recovery.subject_equal?(
              descriptor.fetch(:subject),
              request.subject
            )
          request.completion.fail(
            ArgumentError.new(
              "Recovery subject is not current for execution #{request.execution_id}"
            )
          )
          return
        end

        unless Array(
          descriptor.fetch(:allowed_outcomes)
        ).map(&:to_sym).include?(request.outcome)
          request.completion.fail(
            ArgumentError.new(
              "Recovery outcome #{request.outcome.inspect} is not allowed for the current subject"
            )
          )
          return
        end

        operation = ResolutionOperation.new(
          execution: current,
          root: agent.agent_root,
          subject: request.subject,
          outcome: request.outcome,
          result: request.result,
          failure: request.failure
        )
        event_loop.mark_agent_execution_admission(
          agent.agent_id,
          execution_id: current.execution_id,
          state: :recovery_required
        )
        task = Phronomy::Runtime.instance.offload.submit(
          on_full: :raise
        ) do
          perform_resolution(operation)
        end
        task.on_complete do |result, error|
          ready = ResolveReady.new(
            coordinator: self,
            request: request,
            operation: operation,
            result: result,
            error: error
          )
          unless post_control(ready)
            request.completion.fail(
              Phronomy::RuntimeShutdownError.new(
                "EventLoop rejected Recovery resolution apply"
              )
            )
          end
        end
      rescue => caught
        request.completion.fail(caught)
      end

      def perform_resolution(operation)
        case operation.subject.fetch(:type)
        when :llm_call
          resolve_llm(operation)
        when :tool_invocation
          resolve_tool(operation)
        else
          raise ArgumentError,
            "unsupported Recovery subject: #{operation.subject.inspect}"
        end
      end

      def resolve_llm(operation)
        current = operation.execution
        llm_call_id =
          operation.subject.fetch(:llm_call_id).to_s
        unless current.metadata[
          ACS15RecoverySupport::PENDING_LLM_ID_KEY
        ].to_s == llm_call_id
          raise Phronomy::Persistence::ConflictError,
            "LLM Recovery subject is no longer pending"
        end

        case operation.outcome
        when :not_performed
          # The factual ambiguity is resolved, but ACS-15 deliberately does not
          # invent a generic semantic-retry contract. Without an operation-
          # specific replay contract, fail the logical execution explicitly
          # rather than asking the Application to provide a second, non-factual
          # "resolution" or blindly redispatching the Provider call.
          failure = {
            "class" => "Phronomy::Error",
            "message" =>
              "Recovery confirmed LLM call #{llm_call_id} was not performed; " \
              "automatic semantic redispatch is unavailable without a replay contract"
          }.freeze
          recovery = {
            "version" => ACS15RecoverySupport::CONTRACT_VERSION,
            "resolution_outcome" => "not_performed",
            "failure" => failure
          }.freeze
          updated = current.with(
            phase: :recovery_resolved_failed,
            metadata: current.metadata.merge(
              ACS15RecoverySupport::RECOVERY_METADATA_KEY => recovery
            )
          )
          intended = ResolutionResult.new(
            execution: updated,
            root: operation.root,
            continuation: :failed_terminal,
            failure: failure,
            appended_records: [].freeze
          )
          save_resolution_result(current, intended)
        when :failed
          recovery = {
            "version" => ACS15RecoverySupport::CONTRACT_VERSION,
            "failure" => operation.failure
          }
          updated = current.with(
            phase: :recovery_resolved_failed,
            metadata: current.metadata.merge(
              ACS15RecoverySupport::RECOVERY_METADATA_KEY =>
                recovery
            )
          )
          intended = ResolutionResult.new(
            execution: updated,
            root: operation.root,
            continuation: :failed_terminal,
            failure: operation.failure,
            appended_records: [].freeze
          )
          save_resolution_result(current, intended)
        when :succeeded
          outcome =
            Phronomy::Agent::ProviderCallOutcome.from_h(
              operation.result
            )
          updated = nil
          with_resolution_f1_capture do |tx|
            main = agent.send(:execution_coordinator)
            snapshot = {
              llm_results: [{
                llm_call_id: llm_call_id,
                response: outcome,
                error: nil,
                streaming: (
                  current.metadata[
                    ACS15RecoverySupport::INVOCATION_MODE_KEY
                  ].to_s == "stream"
                ),
                manifest_ref: current.metadata.fetch(
                  "manifest_ref"
                ),
                started_at: current.metadata[
                  ACS15RecoverySupport::PENDING_LLM_STARTED_AT_KEY
                ] || current.updated_at
              }.freeze].freeze,
              runtime_events: [].freeze,
              active_call: nil
            }.freeze
            records, calls = main.send(
              :encode_runtime_records,
              current,
              tx: tx,
              snapshot: snapshot,
              context_candidate: true,
              agent_root: operation.root
            )
            subjects =
              ACS15RecoverySupport.build_tool_subjects(
                current,
                llm_call_id,
                outcome
              )
            next_phase = subjects.empty? ?
              :recovery_provider_completed : :recovery_tools
            metadata = current.metadata.dup
            metadata.delete(
              ACS15RecoverySupport::PENDING_LLM_ID_KEY
            )
            metadata.delete(
              ACS15RecoverySupport::PENDING_LLM_STARTED_AT_KEY
            )
            if subjects.empty?
              metadata.delete(
                ACS15RecoverySupport::RECOVERY_METADATA_KEY
              )
            else
              metadata[
                ACS15RecoverySupport::RECOVERY_METADATA_KEY
              ] = ACS15RecoverySupport.build_recovery_hash(
                subjects
              )
            end
            updated = current.with(
              phase: next_phase,
              working_records:
                current.working_records + records,
              llm_calls: current.llm_calls + calls,
              metadata: metadata
            )
            tx.executions.save(
              current.execution_id,
              expected_revision: current.execution_revision,
              execution: updated
            )
            ResolutionResult.new(
              execution: updated,
              root: operation.root,
              continuation: (
                (updated.phase.to_sym ==
                  :recovery_provider_completed) ?
                    :provider_completed :
                    :resolution_required
              ),
              failure: nil,
              appended_records: [].freeze
            )
          end
        end
      end

      def resolve_tool(operation)
        current = operation.execution
        recovery = ACS15RecoverySupport.recovery_hash(current)
        if recovery.nil? && current.phase.to_sym == :resuming
          subjects = ACS15RecoverySupport.resuming_tool_subjects(current)
          recovery = ACS15RecoverySupport.build_recovery_hash(subjects)
        end
        unless recovery
          raise Phronomy::Persistence::ConflictError,
            "Tool Recovery state is missing"
        end

        subject_entry = Array(
          recovery["subjects"] || recovery[:subjects]
        ).find do |entry|
          hash = entry.to_h { |key, value| [key.to_s, value] }
          hash.fetch("tool_invocation_id").to_s ==
            operation.subject.fetch(:tool_invocation_id).to_s &&
            hash.fetch("state", "unresolved") == "unresolved"
        end
        unless subject_entry
          raise Phronomy::Persistence::ConflictError,
            "Tool Recovery subject is no longer unresolved"
        end
        subject_entry =
          subject_entry.to_h { |key, value| [key.to_s, value] }

        case operation.outcome
        when :not_performed
          tool_id = subject_entry.fetch("tool_invocation_id").to_s
          failure = {
            "class" => "Phronomy::Error",
            "message" =>
              "Recovery confirmed Tool invocation #{tool_id} was not performed; " \
              "automatic semantic redispatch is unavailable without a replay contract"
          }.freeze
          resolved_recovery =
            ACS15RecoverySupport.update_recovery_subject(
              recovery,
              tool_invocation_id: tool_id,
              state: :resolved,
              outcome: :not_performed
            ).merge(
              "resolution_outcome" => "not_performed",
              "failure" => failure
            ).freeze
          updated = current.with(
            phase: :recovery_resolved_failed,
            metadata: current.metadata.merge(
              ACS15RecoverySupport::RECOVERY_METADATA_KEY =>
                resolved_recovery
            )
          )
          intended = ResolutionResult.new(
            execution: updated,
            root: operation.root,
            continuation: :failed_terminal,
            failure: failure,
            appended_records: [].freeze
          )
          save_resolution_result(current, intended)
        when :failed
          recovery_with_failure =
            ACS15RecoverySupport.update_recovery_subject(
              recovery,
              tool_invocation_id:
                subject_entry.fetch("tool_invocation_id"),
              state: :resolved,
              outcome: :failed
            ).merge(
              "failure" => operation.failure
            )
          updated = current.with(
            phase: :recovery_resolved_failed,
            metadata: current.metadata.merge(
              ACS15RecoverySupport::RECOVERY_METADATA_KEY =>
                recovery_with_failure
            )
          )
          intended = ResolutionResult.new(
            execution: updated,
            root: operation.root,
            continuation: :failed_terminal,
            failure: operation.failure,
            appended_records: [].freeze
          )
          save_resolution_result(current, intended)
        when :succeeded
          updated = nil
          with_resolution_f1_capture do |tx|
            main = agent.send(:execution_coordinator)
            result_ref = main.send(
              :put_runtime_content,
              tx,
              operation.result
            )
            message = {
              "role" => "tool",
              "content" => operation.result.to_s,
              "tool_call_id" =>
                subject_entry.fetch("tool_call_id").to_s
            }
            runtime_event = StreamEvent.new(
              type: :tool_result,
              payload: {
                tool_call_id:
                  subject_entry.fetch("tool_call_id").to_s,
                tool_name:
                  subject_entry.fetch("tool_name").to_s,
                tool_result: operation.result,
                tool_message: message,
                llm_call_id:
                  subject_entry.fetch("llm_call_id").to_s
              }.freeze
            )
            records, _calls = main.send(
              :encode_runtime_records,
              current,
              tx: tx,
              snapshot: {
                llm_results: [].freeze,
                runtime_events: [runtime_event].freeze,
                active_call: nil
              }.freeze,
              context_candidate: true,
              agent_root: operation.root
            )
            next_recovery =
              ACS15RecoverySupport.update_recovery_subject(
                recovery,
                tool_invocation_id:
                  subject_entry.fetch("tool_invocation_id"),
                state: :resolved,
                outcome: :succeeded,
                result_ref: result_ref
              )
            unresolved =
              ACS15RecoverySupport.unresolved_subjects(
                next_recovery
              )
            next_phase = unresolved.empty? ?
              :recovery_tools_completed : :recovery_tools
            updated = current.with(
              phase: next_phase,
              working_records:
                current.working_records + records,
              metadata: current.metadata.merge(
                ACS15RecoverySupport::RECOVERY_METADATA_KEY =>
                  next_recovery
              )
            )
            tx.executions.save(
              current.execution_id,
              expected_revision: current.execution_revision,
              execution: updated
            )
            ResolutionResult.new(
              execution: updated,
              root: operation.root,
              continuation: (
                (updated.phase.to_sym ==
                  :recovery_tools_completed) ?
                    :tools_completed :
                    :resolution_required
              ),
              failure: nil,
              appended_records: [].freeze
            )
          end
        end
      end

      def known_non_f1_error?(error)
        error.is_a?(Phronomy::Persistence::ConflictError) ||
          error.is_a?(Phronomy::Persistence::NotFoundError) ||
          error.is_a?(Phronomy::Persistence::SerializationError) ||
          error.is_a?(Phronomy::Persistence::UnsupportedBackendError) ||
          error.is_a?(ArgumentError) ||
          error.is_a?(Phronomy::ConfigurationError)
      end

      def with_resolution_f1_capture
        intended = nil
        begin
          agent.persistence.transaction do |tx|
            intended = yield(tx)
            intended
          end
          intended
        rescue => caught
          raise if known_non_f1_error?(caught)
          raise unless intended

          raise ResolutionOutcomeUnknownError.new(
            caught,
            intended
          )
        end
      end

      def save_resolution_result(current, result)
        with_resolution_f1_capture do |tx|
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: result.execution
          )
          result
        end
      end

      def apply_resolve_on_event_loop(ready)
        request = ready.request
        event_loop = Phronomy::Runtime.instance.event_loop
        state = event_loop.agent_execution_state(
          request.execution_id
        )
        unless state && state.agent.equal?(agent)
          request.completion.fail(
            Phronomy::ExecutionRehydrationRequiredError.new(
              "recovered execution disappeared before resolution apply"
            )
          )
          return
        end

        if ready.error
          reconcile_resolution_f1_on_event_loop(
            ready,
            state
          )
          return
        end

        result = ready.result
        event_loop.replace_agent_execution(
          request.execution_id,
          execution: result.execution
        )

        case result.continuation
        when :resolution_required
          event_loop.mark_agent_execution_admission(
            agent.agent_id,
            execution_id: request.execution_id,
            state: :recovery_required
          )
          descriptor =
            ACS15RecoverySupport.recovery_descriptor(
              result.execution
            )
          deliver_resolution_required(
            result.execution,
            descriptor
          )
          request.completion.complete(
            {
              execution_id: request.execution_id,
              execution_revision:
                result.execution.execution_revision,
              recovery: :resolution_required
            }.freeze
          )
        when :provider_completed
          continue_provider_completed_after_resolution(
            event_loop,
            state,
            result.execution,
            request.completion
          )
        when :tools_completed
          continue_tools_completed_after_resolution(
            event_loop,
            state,
            result.execution,
            request.completion
          )
        when :failed_terminal
          continue_failed_after_resolution(
            event_loop,
            state,
            result.execution,
            request.completion,
            result.failure
          )
        else
          request.completion.fail(
            Phronomy::Error.new(
              "unknown Recovery continuation: #{result.continuation.inspect}"
            )
          )
        end
      rescue => caught
        request.completion.fail(caught)
      end

      def reconcile_resolution_f1_on_event_loop(ready, state)
        request = ready.request
        intended_result = ready.result
        if intended_result.nil? &&
            ready.error.is_a?(ResolutionOutcomeUnknownError)
          intended_result = ready.error.intended_result
        end
        intended = intended_result&.execution
        current = agent.persistence.executions.load(
          request.execution_id
        )

        if intended &&
            current.execution_revision ==
                intended.execution_revision &&
            current.to_h == intended.to_h
          Phronomy::Runtime.instance.event_loop.replace_agent_execution(
            request.execution_id,
            execution: current
          )
          synthetic = ResolveReady.new(
            coordinator: self,
            request: request,
            operation: ready.operation,
            result: intended_result.class.new(
              execution: current,
              root: intended_result.root,
              continuation: intended_result.continuation,
              failure: intended_result.failure,
              appended_records:
                intended_result.appended_records
            ),
            error: nil
          )
          apply_resolve_on_event_loop(synthetic)
          return
        end

        if current.execution_revision ==
            ready.operation.execution.execution_revision &&
            current.to_h ==
                ready.operation.execution.to_h
          failure = if ready.error.is_a?(
            ResolutionOutcomeUnknownError
          )
            ready.error.original_error
          else
            ready.error
          end
          request.completion.fail(failure)
          return
        end

        request.completion.fail(
          Phronomy::Persistence::ConflictError.new(
            "Recovery resolution durable outcome conflicts with both expected pre-state and intended post-state"
          )
        )
      rescue => reconciliation_error
        request.completion.fail(reconciliation_error)
      end

      def continue_provider_completed_after_resolution(
        event_loop,
        old_state,
        execution,
        completion
      )
        manifest_ref = execution.metadata.fetch(
          "manifest_ref"
        )
        _manifest, projection =
          ACS15RecoverySupport.materialize_projection(
            agent,
            manifest_ref
          )
        main = agent.send(:execution_coordinator)
        invocation =
          ACS15RecoverySupport.build_chat_for_recovery(
            agent,
            execution,
            projection,
            main,
            agent.send(:_phronomy_event_listener)
          )
        output, usage =
          ACS15RecoverySupport.provider_output_and_usage(
            agent,
            execution
          )
        invocation.output = output
        invocation.usage = usage
        AgentInvocationSessionBuilder.send(
          :output_filtering_action,
          agent,
          invocation
        )

        event_loop.replace_agent_execution(
          execution.execution_id,
          execution: execution,
          runtime_projection: projection,
          invocation: invocation,
          fsm_session_id: nil
        )
        event_loop.mark_agent_execution_admission(
          agent.agent_id,
          execution_id: execution.execution_id,
          state: :executing
        )
        start_output_completion_session(
          event_loop,
          main,
          execution,
          invocation,
          completion
        )
      end

      def continue_tools_completed_after_resolution(
        event_loop,
        old_state,
        execution,
        completion
      )
        manifest_ref = execution.metadata.fetch(
          "manifest_ref"
        )
        _manifest, projection =
          ACS15RecoverySupport.materialize_projection(
            agent,
            manifest_ref
          )
        main = agent.send(:execution_coordinator)
        invocation =
          ACS15RecoverySupport.build_chat_for_recovery(
            agent,
            execution,
            projection,
            main,
            agent.send(:_phronomy_event_listener)
          )
        event_loop.replace_agent_execution(
          execution.execution_id,
          execution: execution,
          runtime_projection: projection,
          invocation: invocation,
          fsm_session_id: nil
        )
        event_loop.mark_agent_execution_admission(
          agent.agent_id,
          execution_id: execution.execution_id,
          state: :executing
        )
        start_followup_session(
          event_loop,
          main,
          execution,
          invocation,
          completion
        )
      end

      def continue_failed_after_resolution(
        event_loop,
        old_state,
        execution,
        completion,
        failure
      )
        main = agent.send(:execution_coordinator)
        invocation = Phronomy::Agent::AgentInvocation.new(
          agent: agent,
          input: nil,
          config: {
            execution_id: execution.execution_id,
            phronomy_execution_coordinator: main
          },
          event_listener:
            agent.send(:_phronomy_event_listener),
          mode: (
            execution.metadata[
              ACS15RecoverySupport::INVOCATION_MODE_KEY
            ] || "invoke"
          ).to_sym,
          execution_id: execution.execution_id
        )
        event_loop.replace_agent_execution(
          execution.execution_id,
          execution: execution,
          invocation: invocation,
          fsm_session_id: nil
        )
        state = event_loop.agent_execution_state(
          execution.execution_id
        )
        main.send(
          :begin_terminal_commit_on_event_loop,
          state,
          completion,
          invocation,
          ACS15RecoverySupport.error_from_failure(failure),
          fsm_session_id: nil
        )
      end

      def start_output_completion_session(
        event_loop,
        main,
        execution,
        invocation,
        completion
      )
        session =
          AgentInvocationSessionBuilder.build_for_resume(
            agent_invocation: invocation,
            resume_event: :state_completed,
            resume_phase: :output_filtering,
            runtime: Phronomy::Runtime.instance
          )
        event_loop.replace_agent_execution(
          execution.execution_id,
          invocation: invocation,
          fsm_session_id: session.id
        )
        event_loop.register_agent_completion_waiter(
          execution.execution_id,
          completion
        )
        source = Phronomy::Task.deferred(
          name: "#{completion.name}-source"
        )
        source.on_complete do |completed, error|
          main.send(
            :finish_on_event_loop,
            execution.execution_id,
            completion,
            completed || session.context,
            error,
            fsm_session_id: session.id
          )
        end
        event_loop.register(session, completion: source)
      end

      def start_followup_session(
        event_loop,
        main,
        execution,
        invocation,
        completion
      )
        session =
          AgentInvocationSessionBuilder.build_for_resume(
            agent_invocation: invocation,
            resume_event: :state_completed,
            resume_phase: :recording_tool_results,
            runtime: Phronomy::Runtime.instance
          )
        event_loop.replace_agent_execution(
          execution.execution_id,
          invocation: invocation,
          fsm_session_id: session.id
        )
        event_loop.register_agent_completion_waiter(
          execution.execution_id,
          completion
        )
        source = Phronomy::Task.deferred(
          name: "#{completion.name}-source"
        )
        source.on_complete do |completed, error|
          main.send(
            :finish_on_event_loop,
            execution.execution_id,
            completion,
            completed || session.context,
            error,
            fsm_session_id: session.id
          )
        end
        event_loop.register(session, completion: source)
      end

      def deliver_resolution_required(execution, descriptor)
        unless descriptor
          raise Phronomy::ExecutionRehydrationRequiredError,
            "Recovery state has no current unresolved subject"
        end
        listener = agent.send(:_phronomy_event_listener)
        unless listener
          raise Phronomy::ConfigurationError,
            "Recovery resolution requires an Agent on_event listener"
        end
        payload = ACS15RecoverySupport.event_payload(
          execution,
          descriptor
        )
        callback_error = agent.send(
          :_deliver_stream_event,
          listener,
          StreamEvent.new(
            type: :recovery_resolution_required,
            payload: payload
          )
        )
        if callback_error
          raise agent.send(
            :_build_stream_callback_error,
            event_type: :recovery_resolution_required,
            callback_error: callback_error,
            result: payload
          )
        end
        nil
      end

      def post_control(command)
        Phronomy::Runtime.instance.event_loop.post(
          Phronomy::Event.new(
            type: :agent_control,
            target_id:
              Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {command: command}.freeze
          )
        )
      rescue Phronomy::RuntimeShutdownError
        false
      end
    end

    # Assign the already-durable semantic LLM call identity before physical
    # Provider dispatch.
    module ACS15AgentInvocation
      def begin_llm_call!(projection, llm_call_id: nil)
        durable_id = llm_call_id
        if durable_id.nil? &&
            Phronomy::Runtime.instance.event_loop.current?
          state =
            Phronomy::Runtime.instance.event_loop.agent_execution_state(
              execution_id
            )
          durable_id = state&.execution&.metadata&.fetch(
            ACS15RecoverySupport::PENDING_LLM_ID_KEY,
            nil
          )
        end
        unless durable_id
          raise Phronomy::ExecutionRehydrationRequiredError,
            "Provider Call semantic identity was not durably established before dispatch"
        end
        super(projection, llm_call_id: durable_id)
      end
    end

    # Use deterministic ToolInvocation IDs so an unknown Tool outcome can be
    # referred to by the same semantic ID after process loss even if dispatch
    # preceded the next durable barrier.
    module ACS15AgentInvocationSessionBuilder
      def starting_tools_action(
        runtime,
        parent_event_sink,
        invocation
      )
        children = invocation.pending_tool_calls.map do |tool_call|
          tool = invocation.chat.tools[tool_call.name.to_sym]
          tool_invocation_id =
            ACS15RecoverySupport.semantic_tool_id(
              execution_id: invocation.execution_id,
              llm_call_id:
                invocation.tool_batch_llm_call_id,
              tool_call_id:
                (
                  tool_call.respond_to?(:id) ?
                    tool_call.id : nil
                ),
              tool_name: tool_call.name
            )
          if tool
            ToolInvocation.new(
              execution_id: invocation.execution_id,
              agent: invocation.agent,
              tool: tool,
              tool_call: tool_call,
              config: invocation.config,
              approval_policy:
                invocation.approval_policy,
              approval_context:
                invocation.approval_context,
              id: tool_invocation_id
            )
          else
            ToolInvocation.missing(
              execution_id: invocation.execution_id,
              agent: invocation.agent,
              tool_call: tool_call,
              config: invocation.config,
              id: tool_invocation_id
            )
          end
        end
        invocation.tool_invocations = children

        children.reject(&:terminal?).each do |child|
          session = ToolInvocationSessionBuilder.build(
            tool_invocation: child,
            parent_event_sink: parent_event_sink,
            runtime: runtime
          )
          send(
            :register_child_session,
            runtime,
            child,
            session,
            parent_event_sink
          )
        end
        invocation
      end
    end
  end
end

Phronomy::Agent::Base.prepend(
  Phronomy::Agent::ACS15BaseLifecycle
)
Phronomy::Agent::Base.singleton_class.prepend(
  Phronomy::Agent::ACS15BaseClassLifecycle
)
Phronomy::Agent::ExecutionCoordinator.prepend(
  Phronomy::Agent::ACS15ExecutionCoordinator
)
Phronomy::Agent::AgentInvocation.prepend(
  Phronomy::Agent::ACS15AgentInvocation
)
Phronomy::Agent::AgentInvocationSessionBuilder.singleton_class.prepend(
  Phronomy::Agent::ACS15AgentInvocationSessionBuilder
)

if Phronomy::Agent::Base.method_defined?(:on_tool_approval_required)
  Phronomy::Agent::Base.class_eval do
    undef_method :on_tool_approval_required
  end
end
