# frozen_string_literal: true

module Phronomy
  module Agent
    module Immutable
      module_function

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

      def validate_canonical_json!(value, label: "value")
        Phronomy::CanonicalJSON.dump(value)
        true
      rescue ArgumentError => error
        raise ArgumentError, "#{label} is not canonical JSON compatible: #{error.message}"
      end
    end
  end
end
