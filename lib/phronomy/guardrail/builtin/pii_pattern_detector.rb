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
          my_number: {
            pattern: /(?<!\d)(?<!\d[- ])\d{4}[- ]?\d{4}[- ]?\d{4}(?![- ]?\d)/,
            label: "My Number"
          },
          # Credit / debit card: 16 digits, optionally separated by spaces or hyphens.
          credit_card: {
            pattern: /\b(?:\d{4}[- ]?){3}\d{4}\b/,
            label: "credit card number"
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
            fail!("PII detected in input: #{entry[:label]}") if text.match?(entry[:pattern])
          end
        end
      end
    end
  end
end
