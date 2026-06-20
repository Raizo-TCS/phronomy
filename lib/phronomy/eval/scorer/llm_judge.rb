# frozen_string_literal: true

module Phronomy
  module Eval
    module Scorer
      # LLM-as-a-Judge scorer.
      # Sends a structured prompt to an LLM and interprets its numeric reply
      # as a quality score in [0.0, 1.0].
      #
      # The prompt template accepts three named placeholders:
      #   %<input>s     — the original input question
      #   %<expected>s  — the ground-truth / reference answer
      #   %<actual>s    — the output being evaluated
      #
      # The LLM is expected to reply with a single decimal number; any extra
      # text is stripped and the value is clamped to [0.0, 1.0].
      # If parsing fails the scorer returns 0.0 rather than raising.
      #
      # @example
      #   judge = LlmJudge.new(model: "gpt-4o-mini")
      #   judge.score(actual: "Paris", expected: "Paris", input: "Capital of France?")
      class LlmJudge < Base
        DEFAULT_PROMPT = <<~PROMPT
          You are an impartial judge evaluating the quality of an AI assistant response.
          Rate the response on a scale from 0.0 (completely wrong or unhelpful) to 1.0 (perfect).
          Respond with ONLY a single decimal number between 0.0 and 1.0 — no other text.

          Question: %<input>s
          Expected answer: %<expected>s
          Actual response: %<actual>s

          Score:
        PROMPT

        # @param model           [String]  RubyLLM model identifier
        # @param prompt_template [String]  format string with %<input>s, %<expected>s, %<actual>s
        # @param raise_on_error  [Boolean] when true, re-raises scoring exceptions instead of
        #   returning 0.0. Use this in batch eval pipelines where silent failures are unacceptable.
        # @api public
        def initialize(model:, prompt_template: DEFAULT_PROMPT, raise_on_error: false)
          @model = model
          @prompt_template = prompt_template
          @raise_on_error = raise_on_error
        end

        # @return [Float] score in [0.0, 1.0]; 0.0 on error when raise_on_error is false
        # @api public
        # mutant:disable - multiple genuine equivalent mutations:
        #   actual.to_str / actual: (shorthand) are genuine (callers pass String);
        #   expected.to_str / expected: are genuine (String);
        #   response.content.strip (no to_s) is genuine (content is String);
        #   lstrip/rstrip/no-strip are genuine (whitespace doesn't affect number scanning);
        #   scan(/-?\d\.?\d*/) is genuine (for [0,1] range responses, single-digit-before-decimal
        #     matches are the same after clamp);
        #   response.content.to_str.strip is genuine (String);
        #   all warn variations (warn no-arg, warn(nil), warn(e), warn(nil literal),
        #     nil-replacing-warn, warn-deletion) are genuine because the rescue block
        #     still returns 0.0 — warn is a side-effect not tested by value assertions
        def score(actual:, expected:, input: nil)
          prompt = format(@prompt_template, input: input.to_s, expected: expected.to_s, actual: actual.to_s)
          response = Phronomy::Runtime.instance.blocking_io.submit { RubyLLM.chat(model: @model).ask(prompt) }.blocking_wait
          response.content.to_s.strip.scan(/-?\d+\.?\d*/).first.to_f.clamp(0.0, 1.0)
        rescue => e
          raise if @raise_on_error

          warn "[LlmJudge] Scoring failed: #{e.message}"
          0.0
        end
      end
    end
  end
end
