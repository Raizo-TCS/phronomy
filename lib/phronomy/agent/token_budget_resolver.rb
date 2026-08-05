# frozen_string_literal: true

module Phronomy
  module Agent
    # Resolves a TokenBudget from the effective model configuration that will
    # actually be materialized for one LLM call.
    class TokenBudgetResolver
      def initialize(agent:)
        @agent = agent
      end

      def resolve(model_config)
        config = stringify_keys(model_config)
        model_name = config["model"]
        explicit_window = integer_or_nil(config["context_window"])
        explicit_reserve = integer_or_nil(config["max_output_tokens"])

        if explicit_window
          reserve = explicit_reserve || configured_default_reserve
          return build_budget(explicit_window, reserve, model_name)
        end

        return nil unless model_name

        model = RubyLLM.models.find(model_name)
        return nil unless model

        context_window = model.context_window.to_i
        registry_max = model.max_output_tokens.to_i
        reserve = explicit_reserve || configured_default_reserve
        reserve ||= registry_max if registry_max.positive? && registry_max < context_window
        build_budget(context_window, reserve, model_name)
      rescue RubyLLM::ModelNotFoundError
        nil
      end

      private

      def build_budget(context_window, reserve, model_name)
        unless reserve && reserve.positive? && reserve < context_window
          raise Phronomy::InvalidContextBudgetConfigurationError,
            "Cannot determine a valid output reserve for model #{model_name.inspect}; " \
            "set max_output_tokens or Phronomy.configuration.default_output_reserve"
        end

        Phronomy::LlmContextWindow::TokenBudget.new(
          context_window: context_window,
          max_output_tokens: reserve,
          overhead: @agent.class.context_overhead
        )
      end

      def configured_default_reserve
        integer_or_nil(Phronomy.configuration.default_output_reserve)
      end

      def integer_or_nil(value)
        return nil if value.nil?
        Integer(value)
      end

      def stringify_keys(hash)
        hash.to_h.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
      end
    end
  end
end
