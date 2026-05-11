# frozen_string_literal: true

module Phronomy
  module Guardrail
    module Builtin
      # Input guardrail that detects common PII patterns in the input string.
      #
      # Four categories are supported and each can be individually toggled:
      #
      # - +:my_number+   — Japanese My Number (12-digit national ID)
      # - +:credit_card+ — Credit / debit card numbers
      # - +:email+       — E-mail addresses
      # - +:phone+       — Japanese domestic phone numbers
      #
      # All four categories are active by default.
      #
      # @example Default — all categories active:
      #   agent.add_input_guardrail(Phronomy::Guardrail::Builtin::PIIPatternDetector.new)
      #
      # @example Only check for credit cards and email:
      #   detector = Phronomy::Guardrail::Builtin::PIIPatternDetector.new(
      #     detect: [:credit_card, :email]
      #   )
      class PIIPatternDetector < InputGuardrail
        # Recognised PII categories and their detection patterns.
        PATTERNS = {
          # Japanese My Number: 12 consecutive or grouped digits (4-4-4).
          # Matched candidates are additionally validated with the official check-digit
          # algorithm (JIS X 0076) to eliminate false positives from arbitrary 12-digit strings.
          my_number: {
            pattern: /(?<!\d)(?<!\d[- ])\d{4}[- ]?\d{4}[- ]?\d{4}(?![- ]?\d)/,
            label: "My Number",
            validate_my_number: true
          },
          # Credit / debit card: 16 digits, optionally separated by spaces or hyphens.
          # Matched candidates are additionally validated with the Luhn algorithm
          # to eliminate false positives from arbitrary 16-digit sequences.
          credit_card: {
            pattern: /\b(?:\d{4}[- ]?){3}\d{4}\b/,
            label: "credit card number",
            validate_luhn: true
          },
          # Email address (simplified RFC 5322).
          email: {
            pattern: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
            label: "email address"
          },
          # Japanese phone number: starts with 0, groups of 2-5 / 1-4 / 4 digits.
          phone: {
            pattern: /\b0\d{1,4}[- ]?\d{1,4}[- ]?\d{4}\b/,
            label: "phone number"
          }
        }.freeze

        ALL_CATEGORIES = PATTERNS.keys.freeze

        # @param detect [Array<Symbol>] categories to detect.
        #   Defaults to all four: +:my_number+, +:credit_card+, +:email+, +:phone+.
        # @raise [ArgumentError] when an unknown category symbol is provided.
        def initialize(detect: ALL_CATEGORIES)
          unknown = Array(detect) - ALL_CATEGORIES
          raise ArgumentError, "Unknown PII categories: #{unknown.inspect}" if unknown.any?

          @active_patterns = Array(detect).map { |cat| PATTERNS.fetch(cat) }
        end

        # @param value [Object] the input to check
        # @raise [Phronomy::GuardrailError] when a PII pattern is matched,
        #   with a message identifying the category.
        def check(value)
          text = value.to_s
          @active_patterns.each do |entry|
            detected = if entry[:validate_luhn]
              # Scan for all candidates then filter by Luhn check-digit validation.
              # This avoids false positives on arbitrary 16-digit strings (e.g. internal IDs).
              text.scan(entry[:pattern]).any? { |m| luhn_valid?(m.gsub(/[- ]/, "")) }
            elsif entry[:validate_my_number]
              # Scan for all candidates then apply the JIS X 0076 check-digit algorithm.
              # This avoids false positives on arbitrary 12-digit strings.
              text.scan(entry[:pattern]).any? { |m| my_number_valid?(m.gsub(/[- ]/, "")) }
            else
              text.match?(entry[:pattern])
            end
            fail!("PII detected in input: #{entry[:label]}") if detected
          end
        end

        private

        # Returns true when +digits+ (a 12-character string of decimal digits) satisfies
        # the Japanese My Number check-digit algorithm defined in JIS X 0076.
        # The check digit is the 12th digit.
        def my_number_valid?(digits)
          weights = [6, 5, 4, 3, 2, 7, 6, 5, 4, 3, 2]
          total = weights.each_with_index.sum { |w, i| w * digits[i].to_i }
          remainder = total % 11
          check = (remainder <= 1) ? 0 : 11 - remainder
          check == digits[11].to_i
        end

        # Returns true when +digits+ (a string of decimal digits) satisfies the
        # Luhn check-digit algorithm used by payment card networks.
        def luhn_valid?(digits)
          digits.chars.reverse.each_with_index.sum do |d, i|
            n = d.to_i
            if i.odd?
              doubled = n * 2
              (doubled > 9) ? (doubled - 9) : doubled
            else
              n
            end
          end % 10 == 0
        end
      end
    end
  end
end
