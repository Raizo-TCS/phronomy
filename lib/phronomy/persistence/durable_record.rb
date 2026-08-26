# frozen_string_literal: true

module Phronomy
  class Persistence
    # Immutable logical record exchanged across the Persistence Backend SPI.
    #
    # Phronomy owns +record_type+, +format_version+, and the semantic meaning of
    # +payload+. A backend owns only the physical representation used to store
    # the record and must return an equivalent DurableRecord on read.
    #
    # @api public
    class DurableRecord
      FORMAT_VERSION_PATTERN = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/
      MISSING = Object.new.freeze

      # @return [String]
      # @api public
      attr_reader :record_type

      # @return [String]
      # @api public
      attr_reader :format_version

      # @return [Hash{String => Object}]
      # @api public
      attr_reader :payload

      # @api public
      def initialize(record_type: MISSING, format_version: MISSING, payload: MISSING)
        if record_type.equal?(MISSING)
          raise Phronomy::Persistence::SerializationError, "durable record_type is missing"
        end
        if format_version.equal?(MISSING)
          raise Phronomy::Persistence::SerializationError, "durable format_version is missing"
        end
        if payload.equal?(MISSING)
          raise Phronomy::Persistence::SerializationError, "durable payload is missing"
        end
        unless record_type.is_a?(String)
          raise Phronomy::Persistence::SerializationError,
            "durable record_type must be a String"
        end
        unless format_version.is_a?(String)
          raise Phronomy::Persistence::SerializationError,
            "durable format_version must be a String"
        end

        @record_type = record_type.dup.freeze
        @format_version = format_version.dup.freeze
        validate_header!
        validate_payload!(payload)
        @payload = immutable_copy(payload)
        freeze
      rescue Phronomy::Persistence::SerializationError
        raise
      rescue => error
        raise Phronomy::Persistence::SerializationError, error.message
      end

      # Returns an independent immutable record with the same logical value.
      # Backends may use this when they need a defensive copy at a storage
      # boundary without knowing anything about the domain object codec.
      #
      # @return [DurableRecord]
      # @api public
      def copy
        self.class.new(
          record_type: record_type,
          format_version: format_version,
          payload: payload
        )
      end

      private

      def validate_header!
        if record_type.empty?
          raise Phronomy::Persistence::SerializationError,
            "durable record_type must not be empty"
        end

        return if FORMAT_VERSION_PATTERN.match?(format_version)

        raise Phronomy::Persistence::SerializationError,
          "invalid durable format_version: #{format_version.inspect}"
      end

      def validate_payload!(payload)
        unless payload.is_a?(Hash)
          raise Phronomy::Persistence::SerializationError,
            "durable payload must be a Hash"
        end

        Phronomy::CanonicalJSON.dump(payload)
        true
      rescue ArgumentError => error
        raise Phronomy::Persistence::SerializationError,
          "durable payload is not canonical JSON compatible: #{error.message}"
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
