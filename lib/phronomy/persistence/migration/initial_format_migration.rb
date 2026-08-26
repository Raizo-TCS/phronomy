# frozen_string_literal: true

module Phronomy
  class Persistence
    module Migration
      # Explicit logical conversion from the pre-S3 unversioned representations
      # present at the ACS-06 fixed base to the initial 0.1 durable formats.
      #
      # This module does not scan a database or write records. A backend-specific
      # migration runner is responsible for physical enumeration, transactions,
      # and replacement. Normal Runtime load never calls these methods.
      #
      # @api public
      module InitialFormatMigration
        PRE_S3_AGENT_ROOT_KEYS = Phronomy::Agent::AgentRoot::ATTRIBUTES.map(&:to_s).freeze
        PRE_S3_AGENT_EXECUTION_KEYS = Phronomy::Agent::AgentExecution::ATTRIBUTES.map(&:to_s).freeze
        PRE_S3_JOURNAL_KEYS = Phronomy::Agent::JournalRecord::ATTRIBUTES.map(&:to_s).freeze
        PRE_S3_LLM_CALL_KEYS = Phronomy::Agent::LLMCallRecord::ATTRIBUTES.map(&:to_s).freeze
        PRE_S3_APPROVAL_REQUIRED_KEYS = %w[id items created_at].freeze
        PRE_S3_APPROVAL_PARENT_KEYS = %w[execution_id agent_invocation_id].freeze
        PRE_S3_APPROVAL_OPTIONAL_KEYS = %w[approved].freeze
        PRE_S3_APPROVAL_ITEM_KEYS = %w[
          tool_invocation_id tool_call_id tool_name arguments facts reason origin metadata
        ].freeze

        module_function

        def agent_root(hash)
          source = stringify_keys(hash)
          validate_exact_keys!(
            source,
            PRE_S3_AGENT_ROOT_KEYS,
            label: "pre-S3 AgentRoot"
          )
          DurableCodec.encode_agent_root(
            Phronomy::Agent::AgentRoot.from_h(source)
          )
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          migration_error("AgentRoot", error)
        end

        def agent_execution(hash)
          source = stringify_keys(hash)
          validate_exact_keys!(
            source,
            PRE_S3_AGENT_EXECUTION_KEYS,
            label: "pre-S3 AgentExecution"
          )
          source["working_records"] = Array(source.fetch("working_records")).map.with_index do |record, index|
            normalize_legacy_journal_record(
              record,
              label: "pre-S3 AgentExecution working_records[#{index}]"
            )
          end
          source["llm_calls"] = Array(source.fetch("llm_calls")).map.with_index do |call, index|
            normalized = stringify_keys(call)
            validate_exact_keys!(
              normalized,
              PRE_S3_LLM_CALL_KEYS,
              label: "pre-S3 AgentExecution llm_calls[#{index}]"
            )
            normalized
          end
          source["approval_request"] = normalize_legacy_approval_request(
            source["approval_request"],
            execution_id: source.fetch("execution_id")
          )
          execution = Phronomy::Agent::AgentExecution.from_h(source)
          DurableCodec.encode_agent_execution(execution)
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          migration_error("AgentExecution", error)
        end

        def journal_record(hash)
          source = normalize_legacy_journal_record(hash, label: "pre-S3 JournalRecord")
          DurableCodec.encode_journal_record(
            Phronomy::Agent::JournalRecord.from_h(source)
          )
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          migration_error("JournalRecord", error)
        end

        def workflow_state(workflow_instance_id:, revision:, snapshot:)
          DurableCodec.encode_workflow_state(
            workflow_instance_id: workflow_instance_id,
            workflow_revision: Integer(revision),
            snapshot: snapshot
          )
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          migration_error("Workflow state", error)
        end

        # LLMInputManifest is a ContentStore codec boundary, not a
        # Persistence::DurableRecord. Its pre-CG-07 integer version 1 is migrated
        # explicitly to the pre-1.0 string version "0.1".
        def llm_input_manifest(hash)
          source = stringify_keys(hash)
          old_version = source.fetch("version")
          unless old_version == 1 || old_version == "1"
            raise Phronomy::Persistence::SerializationError,
              "unsupported pre-S3 LLMInputManifest version: #{old_version.inspect}"
          end
          source["version"] = Phronomy::Agent::LLMInputManifest::VERSION
          Phronomy::Agent::LLMInputManifest.from_h(source).to_h
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          migration_error("LLMInputManifest", error)
        end

        def normalize_legacy_journal_record(hash, label:)
          source = stringify_keys(hash)
          validate_allowed_keys!(
            source,
            required_keys: PRE_S3_JOURNAL_KEYS,
            optional_keys: ["correlation_id"],
            label: label
          )
          source.delete("correlation_id")
          source
        end
        private_class_method :normalize_legacy_journal_record

        def normalize_legacy_approval_request(request, execution_id:)
          return nil unless request

          source = stringify_keys(request)
          validate_allowed_keys!(
            source,
            required_keys: PRE_S3_APPROVAL_REQUIRED_KEYS,
            optional_keys: PRE_S3_APPROVAL_PARENT_KEYS + PRE_S3_APPROVAL_OPTIONAL_KEYS,
            label: "pre-S3 approval_request"
          )
          parents = PRE_S3_APPROVAL_PARENT_KEYS.select { |key| source.key?(key) }
          unless parents.length == 1
            raise Phronomy::Persistence::SerializationError,
              "pre-S3 approval_request must contain exactly one parent identity, got #{parents.inspect}"
          end

          items = source.fetch("items")
          unless items.is_a?(Array) && !items.empty?
            raise Phronomy::Persistence::SerializationError,
              "pre-S3 approval_request items must be a non-empty Array"
          end
          source["items"] = items.map.with_index do |item, index|
            normalized = stringify_keys(item)
            validate_exact_keys!(
              normalized,
              PRE_S3_APPROVAL_ITEM_KEYS,
              label: "pre-S3 approval_request items[#{index}]"
            )
            normalized
          end

          if source.key?("agent_invocation_id")
            source.delete("agent_invocation_id")
            source["execution_id"] = execution_id.to_s
          elsif source.fetch("execution_id").to_s != execution_id.to_s
            raise Phronomy::Persistence::SerializationError,
              "pre-S3 approval_request execution_id does not match AgentExecution"
          end
          source
        end
        private_class_method :normalize_legacy_approval_request

        def validate_allowed_keys!(hash, required_keys:, optional_keys:, label:)
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
        private_class_method :validate_allowed_keys!

        def validate_exact_keys!(hash, expected_keys, label:)
          validate_allowed_keys!(
            hash,
            required_keys: expected_keys,
            optional_keys: [],
            label: label
          )
        end
        private_class_method :validate_exact_keys!

        def stringify_keys(hash)
          unless hash.is_a?(Hash)
            raise Phronomy::Persistence::SerializationError,
              "migration input must be a Hash"
          end
          hash.each_with_object({}) do |(key, value), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise Phronomy::Persistence::SerializationError,
                "migration key must be String or Symbol, got #{key.class}"
            end
            string_key = key.to_s
            if result.key?(string_key)
              raise Phronomy::Persistence::SerializationError,
                "duplicate migration key after normalization: #{string_key.inspect}"
            end
            result[string_key] = value
          end
        end
        private_class_method :stringify_keys

        def migration_error(label, error)
          raise Phronomy::Persistence::SerializationError,
            "cannot migrate pre-S3 #{label}: #{error.class}: #{error.message}"
        end
        private_class_method :migration_error
      end
    end
  end
end
