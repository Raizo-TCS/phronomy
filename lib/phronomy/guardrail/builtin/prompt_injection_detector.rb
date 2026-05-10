# frozen_string_literal: true

module Phronomy
  module Guardrail
    module Builtin
      # Input guardrail that detects common prompt injection attempts.
      #
      # Matches a built-in list of injection patterns (case-insensitive) and raises
      # {Phronomy::GuardrailError} when any pattern is found in the input string.
      # Additional patterns can be supplied via the +additional_patterns:+ argument.
      #
      # **Limitations**: the built-in patterns cover well-known English and Japanese
      # phrasings. Obfuscated, Base64-encoded, or novel injection phrasing may not
      # be detected. For higher-assurance use cases, combine this guardrail with an
      # LLM-based classifier.
      #
      # @example
      #   agent.add_input_guardrail(
      #     Phronomy::Guardrail::Builtin::PromptInjectionDetector.new
      #   )
      #
      #   # With extra patterns:
      #   detector = Phronomy::Guardrail::Builtin::PromptInjectionDetector.new(
      #     additional_patterns: [/do anything now/i]
      #   )
      class PromptInjectionDetector < InputGuardrail
        # Default patterns that signal a prompt injection attempt.
        DEFAULT_PATTERNS = [
          # --- English patterns ---
          /ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)/i,
          /disregard\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)/i,
          /forget\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)/i,
          /\bsystem\s*prompt\s*:/i,
          /\byou\s+are\s+now\s+(?:a|an)\b/i,
          /\bact\s+as\s+(?:a|an)\b/i,
          /\bpretend\s+(?:you\s+are|to\s+be)\b/i,
          /\bjailbreak\b/i,
          /\bdan\s*mode\b/i,
          /\bdev(?:eloper)?\s*mode\b/i,
          # --- Japanese patterns ---
          /以前の(指示|ルール|プロンプト)を無視/,
          /指示を無視して/,
          /ルールを無視して/,
          /あなたは今(から)?(?!助けて)/,
          /システムプロンプト/,
          /制約(を|から)無視/,
          /制限(を|から)解除/
        ].freeze

        # @param additional_patterns [Array<Regexp>] extra patterns to check in addition
        #   to the built-in list.
        def initialize(additional_patterns: [])
          @patterns = DEFAULT_PATTERNS + Array(additional_patterns)
        end

        # @param value [Object] the input to check
        # @raise [Phronomy::GuardrailError] when an injection pattern is matched
        def check(value)
          text = value.to_s
          @patterns.each do |pattern|
            fail!("Potential prompt injection detected") if text.match?(pattern)
          end
        end
      end
    end
  end
end
