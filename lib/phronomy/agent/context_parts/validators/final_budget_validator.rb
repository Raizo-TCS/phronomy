# frozen_string_literal: true

module Phronomy
  module Agent
    module ContextParts
      module Validators
        class FinalBudgetValidator
          def initialize(content_loader:)
            @content_loader = content_loader
          end

          def validate!(token_budget:, segments:, extra_values: [])
            return 0 unless token_budget

            estimated = Array(segments).sum do |segment|
              Phronomy::LlmContextWindow::TokenEstimator.estimate(
                @content_loader.call(segment.fetch(:content_ref))
              )
            end
            estimated += Array(extra_values).sum do |value|
              bytes = value.is_a?(String) ? value : Phronomy::CanonicalJSON.dump(value)
              Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes)
            end

            limit = token_budget.effective_input_limit
            if estimated > limit
              raise Phronomy::ContextBudgetExceededError,
                "Canonical LLM input (estimated #{estimated} tokens) exceeds " \
                "available input budget (#{limit} tokens)"
            end
            estimated
          end
        end
      end
    end
  end
end
