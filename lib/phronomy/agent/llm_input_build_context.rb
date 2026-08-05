# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable metadata passed to before_llm_input hooks. Runtime objects such
    # as RubyLLM::Chat, messages and the mutable Agent instance are not exposed.
    LLMInputBuildContext = Data.define(
      :agent_id, :agent_definition_id, :definition_version,
      :config, :call_sequence
    ) do
      def initialize(**values)
        super(**values.merge(config: Immutable.copy(values.fetch(:config, {}))))
        freeze
      end
    end
  end
end
