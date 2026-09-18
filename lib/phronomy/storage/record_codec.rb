# frozen_string_literal: true

module Phronomy
  module Storage
    # Shared record-envelope and scalar validation; domain schemas live with their domains.
    # @api private
    module RecordCodec
      private

      def current_payload!(record, record_type:, format_version:, keys:, label:)
        unless record.is_a?(Phronomy::Storage::DurableRecord)
          raise Phronomy::Storage::SerializationError,
            "backend returned #{record.class}; expected Storage::DurableRecord"
        end
        unless record.record_type == record_type
          raise Phronomy::Storage::SerializationError,
            "durable record type mismatch: expected #{record_type.inspect}, " \
            "got #{record.record_type.inspect}"
        end
        unless record.format_version == format_version
          raise Phronomy::Storage::SerializationError,
            "unsupported #{record_type} format version: #{record.format_version.inspect}; " \
            "current version is #{format_version.inspect}"
        end
        validate_exact_keys!(record.payload, keys, label: label)
        record.payload
      end

      def validate_allowed_keys!(hash, required_keys:, optional_keys:, label:)
        unless hash.is_a?(Hash)
          raise Phronomy::Storage::SerializationError, "#{label} must be a Hash"
        end
        unless hash.keys.all? { |key| key.is_a?(String) }
          raise Phronomy::Storage::SerializationError,
            "#{label} keys must all be String"
        end

        actual = hash.keys.sort
        missing = required_keys.sort - actual
        unknown = actual - (required_keys + optional_keys).sort
        return hash if missing.empty? && unknown.empty?

        details = []
        details << "missing=#{missing.inspect}" unless missing.empty?
        details << "unknown=#{unknown.inspect}" unless unknown.empty?
        raise Phronomy::Storage::SerializationError,
          "#{label} schema mismatch (#{details.join(", ")})"
      end

      def validate_exact_keys!(hash, expected_keys, label:)
        unless hash.is_a?(Hash)
          raise Phronomy::Storage::SerializationError, "#{label} must be a Hash"
        end
        unless hash.keys.all? { |key| key.is_a?(String) }
          raise Phronomy::Storage::SerializationError,
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
        raise Phronomy::Storage::SerializationError,
          "#{label} schema mismatch (#{details.join(", ")})"
      end

      def top_level_string_keys(value, label:)
        unless value.is_a?(Hash)
          raise Phronomy::Storage::SerializationError, "#{label} must be a Hash"
        end
        value.each_with_object({}) do |(key, child), result|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise Phronomy::Storage::SerializationError,
              "#{label} key must be String or Symbol, got #{key.class}"
          end
          string_key = key.to_s
          if result.key?(string_key)
            raise Phronomy::Storage::SerializationError,
              "#{label} contains duplicate key after normalization: #{string_key.inspect}"
          end
          result[string_key] = child
        end
      end

      def require_nonempty_string!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(String) && !value.empty?

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be a non-empty String"
      end

      def require_optional_string!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.nil? || value.is_a?(String)

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be a String or nil"
      end

      def require_integer!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(Integer)

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be an Integer"
      end

      def require_positive_integer!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(Integer) && value.positive?

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be a positive Integer"
      end

      def require_nonnegative_integer!(hash, key, label:)
        value = hash.fetch(key)
        return value if value.is_a?(Integer) && value >= 0

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be a non-negative Integer"
      end

      def require_boolean!(hash, key, label:)
        value = hash.fetch(key)
        return value if boolean?(value)

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be true or false"
      end

      def require_enum_string!(hash, key, allowed, label:)
        value = hash.fetch(key)
        return value if value.is_a?(String) && allowed.include?(value)

        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} must be one of #{allowed.inspect}"
      end

      def require_canonical_hash!(hash, key, label:)
        value = hash.fetch(key)
        unless value.is_a?(Hash)
          raise Phronomy::Storage::SerializationError,
            "#{label} #{key} must be a Hash"
        end
        Phronomy::CanonicalJSON.dump(value)
        value
      rescue ArgumentError => error
        raise Phronomy::Storage::SerializationError,
          "#{label} #{key} is not canonical JSON compatible: #{error.message}"
      end

      def boolean?(value)
        value.equal?(true) || value.equal?(false)
      end

      def build_record(record_type, format_version, payload)
        Phronomy::Storage::DurableRecord.new(
          record_type: record_type,
          format_version: format_version,
          payload: payload
        )
      end

      def serialization_error(prefix, error)
        raise Phronomy::Storage::SerializationError,
          "#{prefix}: #{error.class}: #{error.message}"
      end
    end
  end
end
