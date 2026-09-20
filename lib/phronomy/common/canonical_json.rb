# frozen_string_literal: true

require "json"

module Phronomy
  # Phronomy Canonical JSON v1.
  #
  # v1 accepts JSON-native values only, orders object names by UTF-16 code
  # units, and emits ECMAScript/JCS-compatible number forms for IEEE-754
  # doubles. Ruby-specific and non-interoperable numeric values must be
  # converted by a domain codec before serialization.
  class CanonicalJSON
    VERSION = 1
    MAX_SAFE_INTEGER = 9_007_199_254_740_991

    class << self
      def dump(value)
        serialize(value)
      end

      def load(bytes)
        JSON.parse(bytes)
      end

      private

      def serialize(value)
        case value
        when Hash
          serialize_hash(value)
        when Array
          "[#{value.map { |child| serialize(child) }.join(",")}]"
        when String
          JSON.generate(ensure_utf8(value))
        when Integer
          serialize_integer(value)
        when Float
          serialize_float(value)
        when TrueClass then "true"
        when FalseClass then "false"
        when NilClass then "null"
        else
          raise ArgumentError,
            "unsupported Phronomy Canonical JSON v1 value: #{value.class}"
        end
      end

      def serialize_hash(value)
        normalized = {}
        value.each do |key, child|
          unless key.is_a?(String)
            raise ArgumentError,
              "canonical JSON object keys must be String, got #{key.class}"
          end
          canonical_key = ensure_utf8(key)
          if normalized.key?(canonical_key)
            raise ArgumentError,
              "duplicate canonical JSON key: #{canonical_key.inspect}"
          end
          normalized[canonical_key] = child
        end

        members = normalized.sort_by { |key, _| utf16_sort_key(key) }.map do |key, child|
          "#{JSON.generate(key)}:#{serialize(child)}"
        end
        "{#{members.join(",")}}"
      end

      def serialize_integer(value)
        if value.abs > MAX_SAFE_INTEGER
          raise ArgumentError,
            "integer exceeds canonical JSON safe range; encode it as a String: #{value}"
        end
        value.to_s
      end

      def serialize_float(value)
        raise ArgumentError, "non-finite number is not canonical JSON" unless value.finite?
        raise ArgumentError, "-0.0 is not canonical JSON v1" if negative_zero?(value)
        return "0" if value.zero?

        raw = value.to_s.downcase
        return normalize_plain_decimal(raw) unless raw.include?("e")

        sign = raw.start_with?("-") ? "-" : ""
        raw = raw.delete_prefix("-")
        mantissa, exponent_text = raw.split("e", 2)
        exponent = Integer(exponent_text, 10)
        integer_part, fractional_part = mantissa.split(".", 2)
        fractional_part ||= ""
        digits = (integer_part + fractional_part).sub(/0+\z/, "")
        digits = "0" if digits.empty?
        decimal_position = integer_part.length + exponent

        body = if decimal_position > 0 && decimal_position <= 21
          if decimal_position >= digits.length
            digits + ("0" * (decimal_position - digits.length))
          else
            "#{digits[0, decimal_position]}.#{digits[decimal_position..]}"
          end
        elsif decimal_position <= 0 && decimal_position > -6
          "0.#{"0" * -decimal_position}#{digits}"
        else
          scientific_exponent = decimal_position - 1
          fraction = digits[1..]
          coefficient = (fraction.nil? || fraction.empty?) ? digits[0] : "#{digits[0]}.#{fraction}"
          exponent_sign = scientific_exponent.negative? ? "" : "+"
          "#{coefficient}e#{exponent_sign}#{scientific_exponent}"
        end
        "#{sign}#{body}"
      end

      def normalize_plain_decimal(raw)
        raw = raw.delete_suffix(".0")
        (raw == "-0") ? "0" : raw
      end

      def negative_zero?(value)
        value.zero? && (1.0 / value).negative?
      end

      def utf16_sort_key(value)
        value.encode(Encoding::UTF_16BE).bytes
      end

      def ensure_utf8(value)
        text = value.dup.encode(Encoding::UTF_8)
        raise ArgumentError, "invalid UTF-8 string" unless text.valid_encoding?

        text
      rescue EncodingError => error
        raise ArgumentError, "invalid UTF-8 string: #{error.message}"
      end
    end
  end
end
