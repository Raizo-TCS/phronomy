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
