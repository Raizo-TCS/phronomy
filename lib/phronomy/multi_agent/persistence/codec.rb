# frozen_string_literal: true

module Phronomy
  module MultiAgent
    module Persistence
      # Current-format record schemas and conversion for this domain.
      # @api private
      module Codec
        extend Phronomy::Storage::RecordCodec

        module_function

        def encode_team_root(value)
          payload = value.to_h
          Phronomy::MultiAgent::TeamRoot.from_h(payload)
          build_record("phronomy.team_root", "0.1", payload)
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot encode TeamRoot", error)
        end

        def decode_team_root(record)
          payload = current_payload!(record, record_type: "phronomy.team_root",
            format_version: "0.1", keys: Phronomy::MultiAgent::TeamRoot::ATTRIBUTES, label: "TeamRoot")
          Phronomy::MultiAgent::TeamRoot.from_h(payload)
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot decode TeamRoot", error)
        end

        def encode_team_execution(value)
          payload = value.to_h
          Phronomy::MultiAgent::TeamExecution.from_h(payload)
          build_record("phronomy.team_execution", "0.1", payload)
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot encode TeamExecution", error)
        end

        def decode_team_execution(record)
          payload = current_payload!(record, record_type: "phronomy.team_execution",
            format_version: "0.1", keys: Phronomy::MultiAgent::TeamExecution::ATTRIBUTES, label: "TeamExecution")
          Phronomy::MultiAgent::TeamExecution.from_h(payload)
        rescue Phronomy::Storage::SerializationError
          raise
        rescue => error
          serialization_error("cannot decode TeamExecution", error)
        end
      end
    end
  end
end
