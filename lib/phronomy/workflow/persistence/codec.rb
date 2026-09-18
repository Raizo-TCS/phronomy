# frozen_string_literal: true

module Phronomy
  class Workflow
    module Persistence
      # Current-format record schemas and conversion for this domain.
      # @api private
      module Codec
        extend Phronomy::Storage::RecordCodec

        WORKFLOW_STATE_RECORD_TYPE = "phronomy.workflow_state"
        WORKFLOW_STATE_FORMAT_VERSION = "0.1"
        WORKFLOW_STATE_KEYS = %w[
          workflow_instance_id workflow_revision snapshot
        ].freeze

        WORKFLOW_SNAPSHOT_KEYS = %w[fields phase].freeze

        module_function

        def encode_workflow_state(workflow_instance_id:, workflow_revision:, snapshot:)
          normalized_snapshot = canonicalize_workflow_snapshot(snapshot)
          validate_workflow_snapshot!(normalized_snapshot)
          revision = Integer(workflow_revision)
          unless revision.positive?
            raise Phronomy::Storage::SerializationError,
              "Workflow durable revision must be positive"
          end

          payload = {
            "workflow_instance_id" => String(workflow_instance_id),
            "workflow_revision" => revision,
            "snapshot" => normalized_snapshot
          }
          validate_workflow_state_payload!(payload)
          build_record(WORKFLOW_STATE_RECORD_TYPE, WORKFLOW_STATE_FORMAT_VERSION, payload)
        rescue Phronomy::Storage::SerializationError
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
            raise Phronomy::Storage::SerializationError,
              "Workflow state identity mismatch: #{workflow_instance_id.inspect} != " \
              "#{expected_workflow_instance_id.to_s.inspect}"
          end

          {
            snapshot: immutable_copy(payload.fetch("snapshot")),
            revision: payload.fetch("workflow_revision")
          }.freeze
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot decode Workflow state", error)
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
            raise Phronomy::Storage::SerializationError,
              "Workflow snapshot fields must be a Hash"
          end
          phase = snapshot.fetch("phase")
          unless phase.nil? || phase.is_a?(String)
            raise Phronomy::Storage::SerializationError,
              "Workflow snapshot phase must be a String or nil"
          end
          Phronomy::CanonicalJSON.dump(snapshot)
          snapshot
        rescue ArgumentError => error
          raise Phronomy::Storage::SerializationError,
            "Workflow snapshot is not canonical JSON compatible: #{error.message}"
        end

        def canonicalize_workflow_snapshot(snapshot)
          source = top_level_string_keys(snapshot, label: "Workflow snapshot")
          fields = source.fetch("fields")
          unless fields.is_a?(Hash)
            raise Phronomy::Storage::SerializationError,
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
                raise Phronomy::Storage::SerializationError,
                  "Workflow field key must be String or Symbol, got #{key.class}"
              end
              string_key = key.to_s
              if result.key?(string_key)
                raise Phronomy::Storage::SerializationError,
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
            raise Phronomy::Storage::SerializationError,
              "unsupported Workflow durable value: #{value.class}"
          end
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
      end
    end
  end
end
