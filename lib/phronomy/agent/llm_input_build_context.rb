# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable context passed to every before_llm_input hook.
    # Never exposes RubyLLM::Chat, messages arrays, or provider objects.
    LLMInputBuildContext = Data.define(:agent, :config, :call_sequence)
  end
end
