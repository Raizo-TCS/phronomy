# frozen_string_literal: true

module Phronomy
  class Persistence
    # Current-format codec for Phronomy-owned structured Persistence records.
    #
    # Normal Runtime load is current-format-only. Historical conversion belongs
    # to explicit migration code and must never be attempted here.
    #
    # @api private
    module DurableCodec
      AGENT_ROOT_RECORD_TYPE = "phronomy.agent_root"
      AGENT_ROOT_FORMAT_VERSION = "0.1"
      AGENT_EXECUTION_RECORD_TYPE = "phronomy.agent_execution"
      AGENT_EXECUTION_FORMAT_VERSION = "0.1"
      JOURNAL_RECORD_TYPE = "phronomy.journal_record"
      JOURNAL_FORMAT_VERSION = "0.1"
      WORKFLOW_STATE_RECORD_TYPE = "phronomy.workflow_state"
      WORKFLOW_STATE_FORMAT_VERSION = "0.1"

      AGENT_ROOT_KEYS = %w[
        agent_id agent_definition_id agent_definition_version agent_revision
        context_revision journal_position lifecycle_status transcript_generation
        created_at updated_at metadata
      ].freeze

      AGENT_EXECUTION_KEYS = %w[
        execution_id agent_id execution_revision status phase
        base_agent_revision base_context_revision base_journal_position
        working_records llm_calls approval_request result_ref error_ref
        created_at updated_at terminal_reason metadata
      ].freeze

      JOURNAL_RECORD_KEYS = %w[
        record_id agent_id sequence execution_id llm_call_id kind channel role
        content_ref parent_id causation_id visibility context_generation
        context_candidate occurred_at metadata
      ].freeze

      LLM_CALL_RECORD_KEYS = %w[
        llm_call_id execution_id sequence status manifest_ref output_ref
        error_ref usage_ref started_at completed_at metadata
      ].freeze

      APPROVAL_REQUEST_KEYS = %w[id execution_id items created_at].freeze
      APPROVAL_REQUEST_OPTIONAL_KEYS = %w[approved].freeze
      APPROVAL_ITEM_KEYS = %w[
        tool_invocation_id tool_call_id tool_name arguments facts reason origin metadata
      ].freeze
      WORKFLOW_STATE_KEYS = %w[
        workflow_instance_id workflow_revision snapshot
      ].freeze
      WORKFLOW_SNAPSHOT_KEYS = %w[fields phase].freeze

      module_function

      def encode_agent_root(root)
        payload = canonicalize(root.to_h)
        validate_exact_keys!(payload, AGENT_ROOT_KEYS, label: "AgentRoot payload")
        build_record(AGENT_ROOT_RECORD_TYPE, AGENT_ROOT_FORMAT_VERSION, payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot encode AgentRoot", error)
      end

      def decode_agent_root(record)
        payload = current_payload!(
          record,
          record_type: AGENT_ROOT_RECORD_TYPE,
          format_version: AGENT_ROOT_FORMAT_VERSION,
          keys: AGENT_ROOT_KEYS,
          label: "AgentRoot payload"
        )
        Phronomy::Agent::AgentRoot.from_h(payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode AgentRoot", error)
      end

      def encode_agent_execution(execution)
        payload = canonicalize(execution.to_h)
        validate_agent_execution_payload!(payload)
        build_record(
          AGENT_EXECUTION_RECORD_TYPE,
          AGENT_EXECUTION_FORMAT_VERSION,
          payload
        )
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot encode AgentExecution", error)
      end

      def decode_agent_execution(record)
        payload = current_payload!(
          record,
          record_type: AGENT_EXECUTION_RECORD_TYPE,
          format_version: AGENT_EXECUTION_FORMAT_VERSION,
          keys: AGENT_EXECUTION_KEYS,
          label: "AgentExecution payload"
        )
        validate_agent_execution_payload!(payload)
        Phronomy::Agent::AgentExecution.from_h(payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode AgentExecution", error)
      end

      def encode_journal_record(journal_record)
        payload = canonicalize(journal_record.to_h)
        validate_exact_keys!(payload, JOURNAL_RECORD_KEYS, label: "JournalRecord payload")
        build_record(JOURNAL_RECORD_TYPE, JOURNAL_FORMAT_VERSION, payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot encode JournalRecord", error)
      end

      def decode_journal_record(record)
        payload = current_payload!(
          record,
          record_type: JOURNAL_RECORD_TYPE,
          format_version: JOURNAL_FORMAT_VERSION,
          keys: JOURNAL_RECORD_KEYS,
          label: "JournalRecord payload"
        )
        Phronomy::Agent::JournalRecord.from_h(payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode JournalRecord", error)
      end

      def encode_workflow_state(workflow_instance_id:, workflow_revision:, snapshot:)
        normalized_snapshot = canonicalize(snapshot)
        validate_workflow_snapshot!(normalized_snapshot)
        revision = Integer(workflow_revision)
        unless revision.positive?
          raise Phronomy::Persistence::SerializationError,
            "Workflow durable revision must be positive"
        end

        payload = {
          "workflow_instance_id" => String(workflow_instance_id),
          "workflow_revision" => revision,
          "snapshot" => normalized_snapshot
        }
        validate_exact_keys!(payload, WORKFLOW_STATE_KEYS, label: "Workflow state payload")
        build_record(WORKFLOW_STATE_RECORD_TYPE, WORKFLOW_STATE_FORMAT_VERSION, payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot encode Workflow state", error)
      end

      def decode_workflow_state(record, expected_workflow_instance_id: nil)
        payload = current_payload!(
          record,
          record_type: WORKFLOW_STATE_RECORD_TYPE,
          format_version: WORKFLOW_STATE_FORMAT_VERSION,
          keys: WORKFLOW_STATE_KEYS,
          label: "Workflow state payload"
        )
        validate_workflow_snapshot!(payload.fetch("snapshot"))
        workflow_instance_id = payload.fetch("workflow_instance_id")
        if expected_workflow_instance_id &&
            workflow_instance_id != expected_workflow_instance_id.to_s
          raise Phronomy::Persistence::SerializationError,
            "Workflow state identity mismatch: #{workflow_instance_id.inspect} != " \
            "#{expected_workflow_instance_id.to_s.inspect}"
        end
        revision = payload.fetch("workflow_revision")
        unless revision.is_a?(Integer) && revision.positive?
          raise Phronomy::Persistence::SerializationError,
            "Workflow durable revision must be a positive Integer"
        end

        {
          snapshot: immutable_copy(payload.fetch("snapshot")),
          revision: revision
        }.freeze
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode Workflow state", error)
      end

      def validate_agent_execution_payload!(payload)
        validate_exact_keys!(payload, AGENT_EXECUTION_KEYS, label: "AgentExecution payload")

        working_records = payload.fetch("working_records")
        unless working_records.is_a?(Array)
          raise Phronomy::Persistence::SerializationError,
            "AgentExecution working_records must be an Array"
        end
        working_records.each_with_index do |record, index|
          validate_exact_keys!(
            record,
            JOURNAL_RECORD_KEYS,
            label: "AgentExecution working_records[#{index}]"
          )
        end

        llm_calls = payload.fetch("llm_calls")
        unless llm_calls.is_a?(Array)
          raise Phronomy::Persistence::SerializationError,
            "AgentExecution llm_calls must be an Array"
        end
        llm_calls.each_with_index do |call, index|
          validate_exact_keys!(
            call,
            LLM_CALL_RECORD_KEYS,
            label: "AgentExecution llm_calls[#{index}]"
          )
        end

        validate_approval_request!(payload.fetch("approval_request"))
        payload
      end

      def validate_approval_request!(request)
        return if request.nil?

        validate_allowed_keys!(
          request,
          required_keys: APPROVAL_REQUEST_KEYS,
          optional_keys: APPROVAL_REQUEST_OPTIONAL_KEYS,
          label: "approval_request"
        )
        items = request.fetch("items")
        unless items.is_a?(Array) && !items.empty?
          raise Phronomy::Persistence::SerializationError,
            "approval_request items must be a non-empty Array"
        end
        items.each_with_index do |item, index|
          validate_exact_keys!(
            item,
            APPROVAL_ITEM_KEYS,
            label: "approval_request items[#{index}]"
          )
        end
      end

      def validate_workflow_snapshot!(snapshot)
        validate_exact_keys!(snapshot, WORKFLOW_SNAPSHOT_KEYS, label: "Workflow snapshot")
        unless snapshot.fetch("fields").is_a?(Hash)
          raise Phronomy::Persistence::SerializationError,
            "Workflow snapshot fields must be a Hash"
        end
        phase = snapshot.fetch("phase")
        unless phase.nil? || phase.is_a?(String)
          raise Phronomy::Persistence::SerializationError,
            "Workflow snapshot phase must be a String or nil"
        end
        Phronomy::CanonicalJSON.dump(snapshot)
        snapshot
      rescue ArgumentError => error
        raise Phronomy::Persistence::SerializationError,
          "Workflow snapshot is not canonical JSON compatible: #{error.message}"
      end

      def current_payload!(record, record_type:, format_version:, keys:, label:)
        unless record.is_a?(Phronomy::Persistence::DurableRecord)
          raise Phronomy::Persistence::SerializationError,
            "backend returned #{record.class}; expected Persistence::DurableRecord"
        end
        unless record.record_type == record_type
          raise Phronomy::Persistence::SerializationError,
            "durable record type mismatch: expected #{record_type.inspect}, " \
            "got #{record.record_type.inspect}"
        end
        unless record.format_version == format_version
          raise Phronomy::Persistence::SerializationError,
            "unsupported #{record_type} format version: #{record.format_version.inspect}; " \
            "current version is #{format_version.inspect}"
        end
        validate_exact_keys!(record.payload, keys, label: label)
        record.payload
      end

      def validate_allowed_keys!(hash, required_keys:, optional_keys:, label:)
        unless hash.is_a?(Hash)
          raise Phronomy::Persistence::SerializationError, "#{label} must be a Hash"
        end
        unless hash.keys.all? { |key| key.is_a?(String) }
          raise Phronomy::Persistence::SerializationError,
            "#{label} keys must all be String"
        end

        actual = hash.keys.sort
        missing = required_keys.sort - actual
        unknown = actual - (required_keys + optional_keys).sort
        return hash if missing.empty? && unknown.empty?

        details = []
        details << "missing=#{missing.inspect}" unless missing.empty?
        details << "unknown=#{unknown.inspect}" unless unknown.empty?
        raise Phronomy::Persistence::SerializationError,
          "#{label} schema mismatch (#{details.join(", ")})"
      end

      def validate_exact_keys!(hash, expected_keys, label:)
        unless hash.is_a?(Hash)
          raise Phronomy::Persistence::SerializationError, "#{label} must be a Hash"
        end
        unless hash.keys.all? { |key| key.is_a?(String) }
          raise Phronomy::Persistence::SerializationError,
            "#{label} keys must all be String"
        end

        actual = hash.keys.sort
        expected = expected_keys.sort
        return hash if actual == expected

        missing = expected - actual
        unknown = actual - expected
        details = []
        details << "missing=#{missing.inspect}" unless missing.empty?
        details << "unknown=#{unknown.inspect}" unless unknown.empty?
        raise Phronomy::Persistence::SerializationError,
          "#{label} schema mismatch (#{details.join(", ")})"
      end

      def canonicalize(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            string_key = key.is_a?(String) ? key : key.to_s
            if result.key?(string_key)
              raise Phronomy::Persistence::SerializationError,
                "duplicate canonical key after normalization: #{string_key.inspect}"
            end
            result[string_key] = canonicalize(child)
          end
        when Array
          value.map { |child| canonicalize(child) }
        when Symbol
          value.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise Phronomy::Persistence::SerializationError,
            "unsupported durable value: #{value.class}"
        end
      end

      def build_record(record_type, format_version, payload)
        Phronomy::Persistence::DurableRecord.new(
          record_type: record_type,
          format_version: format_version,
          payload: payload
        )
      end

      def immutable_copy(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[key.dup.freeze] = immutable_copy(child)
          end.freeze
        when Array
          value.map { |child| immutable_copy(child) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      def serialization_error(prefix, error)
        raise Phronomy::Persistence::SerializationError,
          "#{prefix}: #{error.class}: #{error.message}"
      end
    end
  end
end
