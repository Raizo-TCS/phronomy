# frozen_string_literal: true

module Phronomy
  class Persistence
    # Current-format codec for Phronomy-owned structured Persistence records.
    #
    # Normal Runtime load is current-format-only. Historical conversion belongs
    # to explicit migration code and must never be attempted here.
    #
    # The codec owns durable schema meaning. Backends receive DurableRecord plus
    # explicit index/CAS metadata from RepositoryFacades; they must not inspect
    # payload fields to rediscover Phronomy semantics.
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
        payload = top_level_string_keys(root.to_h, label: "AgentRoot payload")
        payload["lifecycle_status"] = root.lifecycle_status.to_s
        validate_agent_root_payload!(payload)
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
        validate_agent_root_payload!(payload)
        Phronomy::Agent::AgentRoot.from_h(payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode AgentRoot", error)
      end

      def encode_agent_execution(execution)
        payload = top_level_string_keys(execution.to_h, label: "AgentExecution payload")
        payload["status"] = execution.status.to_s
        payload["phase"] = execution.phase.to_s
        payload["working_records"] = execution.working_records.map do |record|
          journal_payload(record, require_sequence: false)
        end
        payload["llm_calls"] = execution.llm_calls.map do |call|
          llm_call_payload(call)
        end
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
        payload = journal_payload(journal_record, require_sequence: true)
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
        validate_journal_payload!(payload, label: "JournalRecord payload", require_sequence: true)
        Phronomy::Agent::JournalRecord.from_h(payload)
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode JournalRecord", error)
      end

      def encode_workflow_state(workflow_instance_id:, workflow_revision:, snapshot:)
        normalized_snapshot = canonicalize_workflow_snapshot(snapshot)
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
        validate_workflow_state_payload!(payload)
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
        validate_workflow_state_payload!(payload)
        workflow_instance_id = payload.fetch("workflow_instance_id")
        if expected_workflow_instance_id &&
            workflow_instance_id != expected_workflow_instance_id.to_s
          raise Phronomy::Persistence::SerializationError,
            "Workflow state identity mismatch: #{workflow_instance_id.inspect} != " \
            "#{expected_workflow_instance_id.to_s.inspect}"
        end

        {
          snapshot: immutable_copy(payload.fetch("snapshot")),
          revision: payload.fetch("workflow_revision")
        }.freeze
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        serialization_error("cannot decode Workflow state", error)
      end

      def validate_agent_root_payload!(payload)
        validate_exact_keys!(payload, AGENT_ROOT_KEYS, label: "AgentRoot payload")
        require_nonempty_string!(payload, "agent_id", label: "AgentRoot payload")
        require_nonempty_string!(payload, "agent_definition_id", label: "AgentRoot payload")
        require_integer!(payload, "agent_definition_version", label: "AgentRoot payload")
        require_nonnegative_integer!(payload, "agent_revision", label: "AgentRoot payload")
        require_nonnegative_integer!(payload, "context_revision", label: "AgentRoot payload")
        require_nonnegative_integer!(payload, "journal_position", label: "AgentRoot payload")
        require_enum_string!(
          payload,
          "lifecycle_status",
          Phronomy::Agent::AgentRoot::LIFECYCLE_STATUSES.map(&:to_s),
          label: "AgentRoot payload"
        )
        require_nonnegative_integer!(payload, "transcript_generation", label: "AgentRoot payload")
        require_nonempty_string!(payload, "created_at", label: "AgentRoot payload")
        require_nonempty_string!(payload, "updated_at", label: "AgentRoot payload")
        require_canonical_hash!(payload, "metadata", label: "AgentRoot payload")
        payload
      end

      def validate_agent_execution_payload!(payload)
        validate_exact_keys!(payload, AGENT_EXECUTION_KEYS, label: "AgentExecution payload")
        require_nonempty_string!(payload, "execution_id", label: "AgentExecution payload")
        require_nonempty_string!(payload, "agent_id", label: "AgentExecution payload")
        require_nonnegative_integer!(payload, "execution_revision", label: "AgentExecution payload")
        require_enum_string!(
          payload,
          "status",
          Phronomy::Agent::AgentExecution::TRANSITIONS.keys.map(&:to_s),
          label: "AgentExecution payload"
        )
        require_nonempty_string!(payload, "phase", label: "AgentExecution payload")
        require_nonnegative_integer!(payload, "base_agent_revision", label: "AgentExecution payload")
        require_nonnegative_integer!(payload, "base_context_revision", label: "AgentExecution payload")
        require_nonnegative_integer!(payload, "base_journal_position", label: "AgentExecution payload")
        require_optional_string!(payload, "result_ref", label: "AgentExecution payload")
        require_optional_string!(payload, "error_ref", label: "AgentExecution payload")
        require_nonempty_string!(payload, "created_at", label: "AgentExecution payload")
        require_nonempty_string!(payload, "updated_at", label: "AgentExecution payload")
        require_optional_string!(payload, "terminal_reason", label: "AgentExecution payload")
        require_canonical_hash!(payload, "metadata", label: "AgentExecution payload")

        working_records = payload.fetch("working_records")
        unless working_records.is_a?(Array)
          raise Phronomy::Persistence::SerializationError,
            "AgentExecution payload working_records must be an Array"
        end
        working_records.each_with_index do |record, index|
          validate_journal_payload!(
            record,
            label: "AgentExecution working_records[#{index}]",
            require_sequence: false
          )
          record_agent_id = record.fetch("agent_id")
          unless record_agent_id == payload.fetch("agent_id")
            raise Phronomy::Persistence::SerializationError,
              "AgentExecution working_records[#{index}] agent_id mismatch"
          end
          record_execution_id = record.fetch("execution_id")
          if record_execution_id && record_execution_id != payload.fetch("execution_id")
            raise Phronomy::Persistence::SerializationError,
              "AgentExecution working_records[#{index}] execution_id mismatch"
          end
        end

        llm_calls = payload.fetch("llm_calls")
        unless llm_calls.is_a?(Array)
          raise Phronomy::Persistence::SerializationError,
            "AgentExecution payload llm_calls must be an Array"
        end
        llm_calls.each_with_index do |call, index|
          validate_llm_call_payload!(call, label: "AgentExecution llm_calls[#{index}]")
          unless call.fetch("execution_id") == payload.fetch("execution_id")
            raise Phronomy::Persistence::SerializationError,
              "AgentExecution llm_calls[#{index}] execution_id mismatch"
          end
        end

        validate_approval_request!(
          payload.fetch("approval_request"),
          execution_id: payload.fetch("execution_id")
        )
        payload
      end

      def validate_journal_payload!(payload, label:, require_sequence:)
        validate_exact_keys!(payload, JOURNAL_RECORD_KEYS, label: label)
        require_nonempty_string!(payload, "record_id", label: label)
        require_nonempty_string!(payload, "agent_id", label: label)
        sequence = payload.fetch("sequence")
        if require_sequence
          unless sequence.is_a?(Integer) && sequence.positive?
            raise Phronomy::Persistence::SerializationError,
              "#{label} sequence must be a positive Integer"
          end
        elsif !(sequence.nil? || (sequence.is_a?(Integer) && sequence.positive?))
          raise Phronomy::Persistence::SerializationError,
            "#{label} sequence must be nil or a positive Integer"
        end
        require_optional_string!(payload, "execution_id", label: label)
        require_optional_string!(payload, "llm_call_id", label: label)
        require_nonempty_string!(payload, "kind", label: label)
        require_nonempty_string!(payload, "channel", label: label)
        require_optional_string!(payload, "role", label: label)
        require_optional_string!(payload, "content_ref", label: label)
        require_optional_string!(payload, "parent_id", label: label)
        require_optional_string!(payload, "causation_id", label: label)
        require_nonempty_string!(payload, "visibility", label: label)
        require_nonnegative_integer!(payload, "context_generation", label: label)
        require_boolean!(payload, "context_candidate", label: label)
        require_nonempty_string!(payload, "occurred_at", label: label)
        require_canonical_hash!(payload, "metadata", label: label)
        payload
      end

      def validate_llm_call_payload!(payload, label:)
        validate_exact_keys!(payload, LLM_CALL_RECORD_KEYS, label: label)
        require_nonempty_string!(payload, "llm_call_id", label: label)
        require_nonempty_string!(payload, "execution_id", label: label)
        require_positive_integer!(payload, "sequence", label: label)
        require_enum_string!(
          payload,
          "status",
          Phronomy::Agent::LLMCallRecord::STATUSES.map(&:to_s),
          label: label
        )
        require_nonempty_string!(payload, "manifest_ref", label: label)
        require_optional_string!(payload, "output_ref", label: label)
        require_optional_string!(payload, "error_ref", label: label)
        require_optional_string!(payload, "usage_ref", label: label)
        require_nonempty_string!(payload, "started_at", label: label)
        require_optional_string!(payload, "completed_at", label: label)
        require_canonical_hash!(payload, "metadata", label: label)
        payload
      end

      def validate_approval_request!(request, execution_id:)
        return if request.nil?

        validate_allowed_keys!(
          request,
          required_keys: APPROVAL_REQUEST_KEYS,
          optional_keys: APPROVAL_REQUEST_OPTIONAL_KEYS,
          label: "approval_request"
        )
        require_nonempty_string!(request, "id", label: "approval_request")
        require_nonempty_string!(request, "execution_id", label: "approval_request")
        unless request.fetch("execution_id") == execution_id
          raise Phronomy::Persistence::SerializationError,
            "approval_request execution_id mismatch"
        end
        require_nonempty_string!(request, "created_at", label: "approval_request")
        if request.key?("approved") && !boolean?(request.fetch("approved"))
          raise Phronomy::Persistence::SerializationError,
            "approval_request approved must be true or false"
        end

        items = request.fetch("items")
        unless items.is_a?(Array) && !items.empty?
          raise Phronomy::Persistence::SerializationError,
            "approval_request items must be a non-empty Array"
        end
        items.each_with_index do |item, index|
          item_label = "approval_request items[#{index}]"
          validate_exact_keys!(item, APPROVAL_ITEM_KEYS, label: item_label)
          require_nonempty_string!(item, "tool_invocation_id", label: item_label)
          require_optional_string!(item, "tool_call_id", label: item_label)
          require_nonempty_string!(item, "tool_name", label: item_label)
          require_canonical_hash!(item, "arguments", label: item_label)
          require_canonical_hash!(item, "facts", label: item_label)
          require_optional_string!(item, "reason", label: item_label)
          require_nonempty_string!(item, "origin", label: item_label)
          require_canonical_hash!(item, "metadata", label: item_label)
        end
        request
      end

      def validate_workflow_state_payload!(payload)
        validate_exact_keys!(payload, WORKFLOW_STATE_KEYS, label: "Workflow state payload")
        require_nonempty_string!(payload, "workflow_instance_id", label: "Workflow state payload")
        require_positive_integer!(payload, "workflow_revision", label: "Workflow state payload")
        validate_workflow_snapshot!(payload.fetch("snapshot"))
        payload
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

      def top_level_string_keys(value, label:)
        unless value.is_a?(Hash)
          raise Phronomy::Persistence::SerializationError, "#{label} must be a Hash"
        end
        value.each_with_object({}) do |(key, child), result|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise Phronomy::Persistence::SerializationError,
              "#{label} key must be String or Symbol, got #{key.class}"
          end
          string_key = key.to_s
          if result.key?(string_key)
            raise Phronomy::Persistence::SerializationError,
              "#{label} contains duplicate key after normalization: #{string_key.inspect}"
          end
          result[string_key] = child
        end
      end

      # Workflow fields historically normalize Ruby structural keys and Symbol
      # values to strings before durable comparison. Keep that rule explicit and
      # isolated here instead of applying Symbol#to_s generically to every codec.
      def canonicalize_workflow_snapshot(snapshot)
        source = top_level_string_keys(snapshot, label: "Workflow snapshot")
        fields = source.fetch("fields")
        unless fields.is_a?(Hash)
          raise Phronomy::Persistence::SerializationError,
            "Workflow snapshot fields must be a Hash"
        end
        {
          "fields" => canonicalize_workflow_value(fields),
          "phase" => source["phase"]&.to_s
        }
      end

      def canonicalize_workflow_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise Phronomy::Persistence::SerializationError,
                "Workflow field key must be String or Symbol, got #{key.class}"
            end
            string_key = key.to_s
            if result.key?(string_key)
              raise Phronomy::Persistence::SerializationError,
                "duplicate Workflow field key after normalization: #{string_key.inspect}"
            end
            result[string_key] = canonicalize_workflow_value(child)
          end
        when Array
          value.map { |child| canonicalize_workflow_value(child) }
        when Symbol
          value.to_s
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        else
          raise Phronomy::Persistence::SerializationError,
            "unsupported Workflow durable value: #{value.class}"
        end
      end

      def journal_payload(record, require_sequence:)
        payload = top_level_string_keys(record.to_h, label: "JournalRecord payload")
        %w[kind channel role visibility].each do |key|
          value = payload[key]
          payload[key] = value.to_s if value
        end
        validate_journal_payload!(payload, label: "JournalRecord payload", require_sequence: require_sequence)
        payload
      end

      def llm_call_payload(call)
        payload = top_level_string_keys(call.to_h, label: "LLMCallRecord payload")
        payload["status"] = call.status.to_s
        validate_llm_call_payload!(payload, label: "LLMCallRecord payload")
        payload
      end

      def require_nonempty_string!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(String) && !value.empty?

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be a non-empty String"
      end

      def require_optional_string!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.nil? || value.is_a?(String)

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be a String or nil"
      end

      def require_integer!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(Integer)

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be an Integer"
      end

      def require_positive_integer!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(Integer) && value.positive?

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be a positive Integer"
      end

      def require_nonnegative_integer!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(Integer) && value >= 0

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be a non-negative Integer"
      end

      def require_boolean!(hash, key, label:)
        value = hash.fetch(key)
        return value if boolean?(value)

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be true or false"
      end

      def require_enum_string!(hash, key, allowed, label:)
        value = hash.fetch(key)
        return value if value.is_a?(String) && allowed.include?(value)

        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} must be one of #{allowed.inspect}"
      end

      def require_canonical_hash!(hash, key, label:)
        value = hash.fetch(key)
        unless value.is_a?(Hash)
          raise Phronomy::Persistence::SerializationError,
            "#{label} #{key} must be a Hash"
        end
        Phronomy::CanonicalJSON.dump(value)
        value
      rescue ArgumentError => error
        raise Phronomy::Persistence::SerializationError,
          "#{label} #{key} is not canonical JSON compatible: #{error.message}"
      end

      def boolean?(value)
        value.equal?(true) || value.equal?(false)
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
