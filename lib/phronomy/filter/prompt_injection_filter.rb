# frozen_string_literal: true

module Phronomy
  module Filter
    # Detects potential prompt injection attempts in the agent input.
    #
    # Prompt injection is an attack where an adversary embeds LLM instructions
    # inside data sources (e.g. RAG chunks, tool results, user input) to override
    # the agent's intended behaviour.
    #
    # This filter scans the input string for common injection patterns and
    # calls {#block!} when a match is found.  It is intended to be registered as
    # an input filter on agents that consume untrusted external content.
    #
    # @example
    #   class MyAgent < Phronomy::Agent::Base
    #     model "gpt-4o"
    #     input_filter Phronomy::Filter::PromptInjectionFilter
    #   end
    #
    # @example Custom patterns
    #   filter = Phronomy::Filter::PromptInjectionFilter.new(
    #     extra_patterns: [/exfiltrate/i]
    #   )
    #   agent.add_input_filter(filter)
    #
    # @api public
    class PromptInjectionFilter < Base
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
        /\bdo\s+not\s+follow\s+(your|the)\s+instructions?\b/i
      ].freeze

      # @param extra_patterns [Array<Regexp>] additional patterns to scan for
      # @api public
      def initialize(extra_patterns: [])
        super()
        @patterns = DEFAULT_PATTERNS + extra_patterns
      end

      # Scans the input string for injection patterns.
      # @param value [String, Hash]
      # @param context [Hash]
      # @return [String, Hash] the original value when no injection is detected
      # @raise [Phronomy::FilterBlockError] when a pattern matches
      # @api public
      def call(value, **_context)
        text = value.is_a?(Hash) ? value.values.join(" ") : value.to_s
        @patterns.each do |pattern|
          block!("Potential prompt injection detected") if text.match?(pattern)
        end
        value
      end
    end
  end
end
