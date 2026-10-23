# frozen_string_literal: true

require_relative "../canonical_json"

module Phronomy
  module Values
    # Shared value operations for snapshots, recovery facts, and result views.
    # Hash, Array, and String trees are copied and frozen; other values retain
    # their identity. Canonical JSON validation is a separate operation.
    # @api private
    module Immutable
      module_function

      # Normalize JSON object names without coercing values or losing duplicates.
      # @api private
      def json(value, ancestors: [])
        if (value.is_a?(Hash) || value.is_a?(Array)) && ancestors.include?(value.object_id)
          raise ArgumentError, "cyclic JSON value"
        end
        children = ancestors + [value.object_id]
        normalized = case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError, "JSON object keys must be Strings or Symbols"
            end
            name = key.to_s
            raise ArgumentError, "duplicate JSON object key: #{name}" if result.key?(name)
            result[name.dup.freeze] = json(child, ancestors: children)
          end
        when Array then value.map { |child| json(child, ancestors: children) }
        when String
          text = value.encode(Encoding::UTF_8)
          raise ArgumentError, "invalid UTF-8 JSON string" unless text.valid_encoding?
          text.dup
        when Integer, TrueClass, FalseClass, NilClass then value
        when Float
          raise ArgumentError, "JSON numbers must be finite" unless value.finite?
          value
        else raise ArgumentError, "unsupported JSON value: #{value.class}"
        end
        normalized.freeze
      rescue EncodingError
        raise ArgumentError, "invalid UTF-8 JSON string"
      end

      # @api private
      def copy(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[copy(key)] = copy(child)
          end.freeze
        when Array
          value.map { |child| copy(child) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      # @api private
      def validate_canonical_json!(value, label: "value")
        Phronomy::CanonicalJSON.dump(value)
        true
      rescue ArgumentError => error
        raise ArgumentError, "#{label} is not canonical JSON compatible: #{error.message}"
      end
    end
  end
end
