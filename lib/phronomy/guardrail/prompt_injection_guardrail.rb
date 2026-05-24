# frozen_string_literal: true

module Phronomy
  module Guardrail
    # Detects potential prompt injection attempts in the agent input.
    #
    # Prompt injection is an attack where an adversary embeds LLM instructions
    # inside data sources (e.g. RAG chunks, tool results, user input) to override
    # the agent's intended behaviour.
    #
    # This guardrail scans the input string for common injection patterns and
    # calls {#fail!} when a match is found.  It is intended to be registered as
    # an input guardrail on agents that consume untrusted external content.
    #
    # @example
    #   class MyAgent < Phronomy::Agent::Base
    #     model "gpt-4o"
    #     input_guardrails Phronomy::Guardrail::PromptInjectionGuardrail.new
    #   end
    #
    # @example Custom patterns
    #   guard = Phronomy::Guardrail::PromptInjectionGuardrail.new(
    #     extra_patterns: [/exfiltrate/i]
    #   )
    class PromptInjectionGuardrail < InputGuardrail
      # Common prompt injection / jailbreak patterns.
      DEFAULT_PATTERNS = [
        /ignore\s+(previous|prior|all)\s+instructions?/i,
        /disregard\s+(previous|prior|all)\s+instructions?/i,
        /forget\s+(previous|prior|all)\s+instructions?/i,
        /override\s+(previous|prior|all)\s+instructions?/i,
        /new\s+instructions?:\s/i,
        /\byour\s+new\s+(role|instructions?|task)\b/i,
        /you\s+are\s+now\s+(a|an)\b/i,
        /\bact\s+as\s+(a|an)\b/i,
        /\bpretend\s+(you\s+are|to\s+be)\b/i,
        /\bdo\s+not\s+follow\s+(your|the)\s+instructions?\b/i,
      ].freeze

      # @param extra_patterns [Array<Regexp>] additional patterns to scan for
      def initialize(extra_patterns: [])
        super()
        @patterns = DEFAULT_PATTERNS + extra_patterns
      end

      # Scans the input string for injection patterns.
      # @param input [String, Hash]
      def check(input)
        text = input.is_a?(Hash) ? input.values.join(" ") : input.to_s
        @patterns.each do |pattern|
          fail!("Potential prompt injection detected") if text.match?(pattern)
        end
      end
    end
  end
end
