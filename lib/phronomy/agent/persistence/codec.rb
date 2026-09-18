# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Current-format record schemas and conversion for this domain.
      # @api private
      module Codec
        extend Phronomy::Storage::RecordCodec

        AGENT_ROOT_RECORD_TYPE = "phronomy.agent_root"
        AGENT_ROOT_FORMAT_VERSION = "0.1"
        AGENT_EXECUTION_RECORD_TYPE = "phronomy.agent_execution"
        AGENT_EXECUTION_FORMAT_VERSION = "0.1"
        JOURNAL_RECORD_TYPE = "phronomy.journal_record"
        JOURNAL_FORMAT_VERSION = "0.1"
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

        module_function

        def encode_handoff_state(value)
          payload = value.to_h
          Phronomy::Agent::HandoffState.from_h(payload)
          build_record("phronomy.handoff_state", "0.1", payload)
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot encode HandoffState", error)
        end

        def decode_handoff_state(record)
          payload = current_payload!(record, record_type: "phronomy.handoff_state",
            format_version: "0.1", keys: Phronomy::Agent::HandoffState::ATTRIBUTES, label: "HandoffState")
          Phronomy::Agent::HandoffState.from_h(payload)
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot decode HandoffState", error)
        end

        def encode_agent_root(root)
          payload = top_level_string_keys(root.to_h, label: "AgentRoot payload")
          payload["lifecycle_status"] = root.lifecycle_status.to_s
          validate_agent_root_payload!(payload)
          build_record(AGENT_ROOT_RECORD_TYPE, AGENT_ROOT_FORMAT_VERSION, payload)
        rescue Phronomy::Storage::SerializationError
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
        rescue Phronomy::Storage::SerializationError
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
        rescue Phronomy::Storage::SerializationError
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
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot decode AgentExecution", error)
        end

        def encode_journal_record(journal_record)
          payload = journal_payload(journal_record, require_sequence: true)
          build_record(JOURNAL_RECORD_TYPE, JOURNAL_FORMAT_VERSION, payload)
        rescue Phronomy::Storage::SerializationError
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
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot decode JournalRecord", error)
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
            raise Phronomy::Storage::SerializationError,
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
              raise Phronomy::Storage::SerializationError,
                "AgentExecution working_records[#{index}] agent_id mismatch"
            end
            record_execution_id = record.fetch("execution_id")
            if record_execution_id && record_execution_id != payload.fetch("execution_id")
              raise Phronomy::Storage::SerializationError,
                "AgentExecution working_records[#{index}] execution_id mismatch"
            end
          end

          llm_calls = payload.fetch("llm_calls")
          unless llm_calls.is_a?(Array)
            raise Phronomy::Storage::SerializationError,
              "AgentExecution payload llm_calls must be an Array"
          end
          llm_calls.each_with_index do |call, index|
            validate_llm_call_payload!(call, label: "AgentExecution llm_calls[#{index}]")
            unless call.fetch("execution_id") == payload.fetch("execution_id")
              raise Phronomy::Storage::SerializationError,
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
              raise Phronomy::Storage::SerializationError,
                "#{label} sequence must be a positive Integer"
            end
          elsif !(sequence.nil? || (sequence.is_a?(Integer) && sequence.positive?))
            raise Phronomy::Storage::SerializationError,
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
            raise Phronomy::Storage::SerializationError,
              "approval_request execution_id mismatch"
          end
          require_nonempty_string!(request, "created_at", label: "approval_request")
          if request.key?("approved") && !boolean?(request.fetch("approved"))
            raise Phronomy::Storage::SerializationError,
              "approval_request approved must be true or false"
          end

          items = request.fetch("items")
          unless items.is_a?(Array) && !items.empty?
            raise Phronomy::Storage::SerializationError,
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
      end
    end
  end
end
