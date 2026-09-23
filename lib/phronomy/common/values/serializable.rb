# frozen_string_literal: true

module Phronomy
  module Values
    # Prepares a Ruby value tree for JSON serialization. Hash keys and Symbol
    # values become Strings; containers are rebuilt and scalar objects retained.
    # This neither freezes values nor validates canonical JSON numbers/encoding.
    # @api private
    module Serializable
      module_function

      def convert(value, unsupported_message:)
        case value
        when Hash
          value.to_h { |key, child| [key.to_s, convert(child, unsupported_message: unsupported_message)] }
        when Array
          value.map { |child| convert(child, unsupported_message: unsupported_message) }
        when String, Integer, Float, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        else
          if value.respond_to?(:to_h)
            convert(value.to_h, unsupported_message: unsupported_message)
          else
            raise ArgumentError, "#{unsupported_message}: #{value.class}"
          end
        end
      end
    end
  end
end
