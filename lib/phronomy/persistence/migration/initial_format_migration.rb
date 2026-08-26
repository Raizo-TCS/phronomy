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
        module_function

        def agent_root(hash)
          DurableCodec.encode_agent_root(
            Phronomy::Agent::AgentRoot.from_h(stringify_keys(hash))
          )
        rescue Phronomy::Persistence::SerializationError
          raise
        rescue => error
          migration_error("AgentRoot", error)
        end

        def agent_execution(hash)
          source = stringify_keys(hash)
          source["working_records"] = Array(source.fetch("working_records")).map do |record|
            normalize_legacy_journal_record(record)
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
          source = normalize_legacy_journal_record(hash)
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

        def normalize_legacy_journal_record(hash)
          source = stringify_keys(hash)
          source.delete("correlation_id")
          source
        end
        private_class_method :normalize_legacy_journal_record

        def normalize_legacy_approval_request(request, execution_id:)
          return nil unless request

          source = stringify_keys(request)
          if source.key?("agent_invocation_id")
            source.delete("agent_invocation_id")
            source["execution_id"] = execution_id.to_s
          end
          source
        end
        private_class_method :normalize_legacy_approval_request

        def stringify_keys(hash)
          unless hash.is_a?(Hash)
            raise Phronomy::Persistence::SerializationError,
              "migration input must be a Hash"
          end
          hash.each_with_object({}) do |(key, value), result|
            string_key = key.is_a?(String) ? key : key.to_s
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
