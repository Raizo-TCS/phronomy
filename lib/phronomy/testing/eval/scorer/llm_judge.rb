# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      module Scorer
        class LlmJudge < Base
          CLIENT_FACTORIES = {}
          private_constant :CLIENT_FACTORIES

          # One-time boot binding, not an application extension registry. The
          # factory runs for each score, after its Request has been prepared.
          # @api private
          def self.install_client_factory(factory)
            raise ArgumentError, "factory must respond to call" unless factory.respond_to?(:call)

            CLIENT_FACTORIES.replace(client: factory).freeze
            nil
          end

          DEFAULT_PROMPT = <<~PROMPT
            You are an impartial judge evaluating the quality of an AI assistant response.
            Rate the response on a scale from 0.0 (completely wrong or unhelpful) to 1.0 (perfect).
            Respond with ONLY a single decimal number between 0.0 and 1.0 — no other text.

            Question: %<input>s
            Expected answer: %<expected>s
            Actual response: %<actual>s

            Score:
          PROMPT

          def initialize(model:, provider: nil, assume_model_exists: false, prompt_template: DEFAULT_PROMPT, raise_on_error: false)
            @model = model
            @provider = provider
            @assume_model_exists = assume_model_exists
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
            request = Phronomy::LLMAdapter::Request.new(
              model_config: {"model" => @model, "provider" => @provider&.to_s,
                             "assume_model_exists" => @assume_model_exists}.compact,
              message: prompt
            )
            response = CLIENT_FACTORIES.fetch(:client).call.complete_async(request).wait_result
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
