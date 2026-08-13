# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      module Scorer
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

          def initialize(model:, prompt_template: DEFAULT_PROMPT, raise_on_error: false)
            @model = model
            @prompt_template = prompt_template
            @raise_on_error = raise_on_error
          end

          def score(actual:, expected:, input: nil)
            prompt = format(
              @prompt_template,
              input: input.to_s,
              expected: expected.to_s,
              actual: actual.to_s
            )
            response = Phronomy::Runtime.instance.offload.submit do
              RubyLLM.chat(model: @model).ask(prompt)
            end.blocking_wait
            response.content.to_s.strip.scan(/-?\d+\.?\d*/).first.to_f.clamp(0.0, 1.0)
          rescue => error
            raise if @raise_on_error
            warn "[LlmJudge] Scoring failed: #{error.message}"
            0.0
          end
        end
      end
    end
  end
end
