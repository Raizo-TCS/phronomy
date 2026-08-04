# frozen_string_literal: true

module Phronomy
  module Agent
    # Typed result returned by a before_llm_input hook.
    # All fields are optional; nil means "no override for this field".
    #
    # @param model_config_patch        [Hash, nil]  Overrides merged into model config
    #   (model:, temperature:, max_output_tokens:, etc.)
    # @param segment_candidates        [Array<Hash>, nil]  Extra segments to inject.
    #   Each hash: { content: String, category: Symbol, role: Symbol }
    # @param response_schema_candidate [Object, nil]  Structured-output schema override.
    # @param selection_policy_override [Object, nil]  ContextSelector policy override.
    LLMInputPatch = Data.define(
      :model_config_patch,
      :segment_candidates,
      :response_schema_candidate,
      :selection_policy_override
    ) do
      def self.empty
        new(model_config_patch: nil, segment_candidates: nil,
            response_schema_candidate: nil, selection_policy_override: nil)
      end
    end
  end
end
