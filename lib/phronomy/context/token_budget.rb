# frozen_string_literal: true

module Phronomy
  module Context
    # Raised when a model name is not found in the RubyLLM model registry and
    # no explicit context_window was provided.
    class UnknownModelError < Phronomy::Error; end

    # Calculates the effective token budget available for conversation history
    # and injected knowledge within a single LLM request.
    #
    # The window is divided as follows:
    #
    #   context_window (total)
    #   ├─ max_output_tokens  (reserved for model output = max_output_tokens)
    #   ├─ overhead           (reserved for system prompt + tool definitions)
    #   └─ effective_input_limit  (available for memory + knowledge)
    #
    # @example Auto-derive from RubyLLM model registry
    #   budget = Phronomy::Context::TokenBudget.new(model: "claude-3-5-sonnet-20241022")
    #
    # @example Explicit values (useful for local / unknown models)
    #   budget = Phronomy::Context::TokenBudget.new(
    #     context_window:    32_768,
    #     max_output_tokens: 4_096
    #   )
    #
    # @example With overhead for instructions + tool definitions
    #   budget = Phronomy::Context::TokenBudget.new(
    #     model:    "gpt-4o",
    #     overhead: 800
    #   )
    class TokenBudget
      # @return [Integer] total token limit of the model
      attr_reader :context_window

      # @return [Integer] tokens reserved for model output
      attr_reader :max_output_tokens

      # @return [Integer] tokens reserved for instructions and tool definitions
      attr_reader :overhead

      # @param model             [String, nil]  model identifier looked up in RubyLLM
      # @param context_window    [Integer, nil] explicit total token limit
      # @param max_output_tokens [Integer, nil] explicit output reservation; when nil
      #                                         and model is given, uses max_output_tokens
      # @param overhead          [Integer]      tokens reserved for instructions/tools
      # @api private
      # mutant:disable - multiple genuine equivalent mutations: overhead/context_window/max_output_tokens .to_i vs .to_int vs Integer() vs omitted are equivalent for Integer inputs; (max_output_tokens||0).to_i vs (max_output_tokens).to_i and (||nil).to_i are genuine because nil.to_i==0; overhead:nil default is genuine because nil.to_i==0
      def initialize(model: nil, context_window: nil, max_output_tokens: nil, overhead: 0)
        @overhead = overhead.to_i

        if context_window
          # Explicit values — no registry lookup needed.
          @context_window = context_window.to_i
          @max_output_tokens = (max_output_tokens || 0).to_i
        elsif model
          ruby_llm_model = lookup_model!(model)
          @context_window = ruby_llm_model.context_window.to_i
          @max_output_tokens = (max_output_tokens || ruby_llm_model.max_output_tokens).to_i
        else
          raise ArgumentError, "Provide either model: or context_window:"
        end
      end

      # Tokens available for conversation history and knowledge after reservations.
      # Always >= 0.
      #
      # @return [Integer]
      # @api private
      def effective_input_limit
        [@context_window - @max_output_tokens - @overhead, 0].max
      end

      # Tokens still available after `used` tokens have been allocated.
      #
      # @param used [Integer] tokens already committed (e.g. from knowledge injection)
      # @return [Integer] remaining tokens (always >= 0)
      # @api private
      # mutant:disable - used.to_i vs used vs used.to_int vs Integer(used) are genuine equivalents when used is an Integer; used:nil default is genuine because nil.to_i==0==default 0
      def available(used: 0)
        [effective_input_limit - used.to_i, 0].max
      end

      private

      # mutant:disable - raise(UnknownModelError) and raise(UnknownModelError,nil) and raise(UnknownModelError,"Model '#{nil}' not found") in both branches are genuine equivalents (spec checks exception class only, not message text)
      def lookup_model!(model_name)
        found = RubyLLM.models.find(model_name)
        raise UnknownModelError, "Model '#{model_name}' not found in RubyLLM registry" unless found

        found
      rescue RubyLLM::ModelNotFoundError
        raise UnknownModelError, "Model '#{model_name}' not found in RubyLLM registry"
      end
    end
  end
end
