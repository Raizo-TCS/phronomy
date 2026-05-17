# frozen_string_literal: true

module Phronomy
  module Guardrail
    module Builtin
      # Input guardrail that detects common PII patterns in the input string.
      #
      # Four categories are supported and each can be individually toggled:
      #
      # - +:ssn+         — US Social Security Numbers (###-##-####)
      # - +:credit_card+ — Credit / debit card numbers
      # - +:email+       — E-mail addresses
      # - +:phone+       — Phone numbers
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
          # US Social Security Number: ###-##-#### (hyphens required).
          ssn: {
            pattern: /\b\d{3}-\d{2}-\d{4}\b/,
            label: "SSN"
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
          # Phone number: 3-digit area code, 3-4-digit exchange, 4-digit subscriber;
          # optional E.164 country-code prefix (e.g. +1, +44).
          phone: {
            pattern: /(?:\+\d{1,3}[.\- ]?)?\(?\d{3}\)?[.\- ]?\d{3,4}[.\- ]?\d{4}\b/,
            label: "phone number"
          }
        }.freeze

        ALL_CATEGORIES = PATTERNS.keys.freeze

        # @param detect [Array<Symbol>] categories to detect.
        #   Defaults to all four: +:ssn+, +:credit_card+, +:email+, +:phone+.
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
            else
              text.match?(entry[:pattern])
            end
            fail!("PII detected in input: #{entry[:label]}") if detected
          end
        end

        private

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
