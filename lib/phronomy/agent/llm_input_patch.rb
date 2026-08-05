# frozen_string_literal: true

module Phronomy
  module Agent
    # Typed, canonicalizable input customization returned by before_llm_input.
    # v1 deliberately exposes only fields that are fully applied to every call.
    LLMInputPatch = Data.define(:model_config_patch, :segment_candidates) do
      def initialize(model_config_patch: nil, segment_candidates: nil)
        super(
          model_config_patch: model_config_patch && Immutable.copy(model_config_patch),
          segment_candidates: segment_candidates && Immutable.copy(Array(segment_candidates))
        )
        freeze
      end

      def self.empty
        new
      end
    end
  end
end
