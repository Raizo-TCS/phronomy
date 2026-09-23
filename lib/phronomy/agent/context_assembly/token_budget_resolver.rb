# frozen_string_literal: true

module Phronomy
  module Agent
    # Resolves the input limit from RubyLLM's authoritative model registry.
    class TokenBudgetResolver
      def resolve(model_config)
        config = model_config.to_h.transform_keys(&:to_s)
        model_name = config["model"]
        return nil unless model_name

        model = RubyLLM.models.find(model_name, provider: config["provider"])
        limit = model&.context_window
        return nil unless limit.is_a?(Integer) && limit.positive?

        Phronomy::LlmContextWindow::TokenBudget.new(max_input_tokens: limit)
      rescue RubyLLM::ModelNotFoundError
        nil
      end
    end
  end
end
