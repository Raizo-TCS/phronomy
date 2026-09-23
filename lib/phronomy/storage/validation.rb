# frozen_string_literal: true

module Phronomy
  module Storage
    # Input validation shared by storage handles; no physical work happens here.
    # @api private
    module Validation
      module_function

      def key(value)
        raise ArgumentError, "key must be a non-empty String" unless value.is_a?(String) && !value.empty?
        result = value.encode(Encoding::UTF_8)
        raise ArgumentError, "key must be valid UTF-8" unless result.valid_encoding? && !result.include?("\0")
        result.dup.freeze
      rescue EncodingError
        raise ArgumentError, "key must be valid UTF-8"
      end

      def revision(value)
        raise ArgumentError, "revision must be a non-negative Integer" unless value.is_a?(Integer) && value >= 0
        value
      end

      def limit(value)
        return nil if value.nil?
        raise ArgumentError, "limit must be a positive Integer" unless value.is_a?(Integer) && value.positive?
        value
      end

      def record(value)
        raise SerializationError, "expected Storage::DurableRecord" unless value.is_a?(DurableRecord)
        value.copy
      end

      def reference(value)
        value.is_a?(Resource) ? value : key(value)
      end

      def attributes(value)
        unless value.is_a?(Hash) && value.all? { |name, item| name.is_a?(Symbol) && [String, Integer, TrueClass, FalseClass, NilClass].any? { |type| item.is_a?(type) } }
          raise ArgumentError, "attributes must contain named scalar values"
        end
        immutable(value)
      end

      def immutable(value)
        case value
        when Hash then value.to_h { |k, v| [immutable(k), immutable(v)] }.freeze
        when Array then value.map { |v| immutable(v) }.freeze
        when String then value.dup.freeze
        when Symbol, Integer, TrueClass, FalseClass, NilClass then value
        else raise ArgumentError, "declarations must contain immutable scalar values"
        end
      end
    end
  end
end
