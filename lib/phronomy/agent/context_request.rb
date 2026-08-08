# frozen_string_literal: true

module Phronomy
  module Agent
    ContextRequest = Data.define(
      :agent_id,
      :execution_id,
      :call_sequence,
      :call_mode,
      :candidates,
      :token_budget,
      :model_config,
      :previous_manifest,
      :required_coverage,
      :parts,
      :metadata
    ) do
      def initialize(**values)
        super(**values.merge(
          agent_id: values.fetch(:agent_id).to_s.freeze,
          execution_id: values[:execution_id]&.to_s&.freeze,
          call_sequence: Integer(values.fetch(:call_sequence)),
          call_mode: values.fetch(:call_mode).to_sym,
          candidates: Array(values[:candidates]).freeze,
          model_config: Immutable.copy(values[:model_config] || {}),
          required_coverage: Array(values[:required_coverage]).map(&:to_s).freeze,
          parts: (values[:parts] || {}).dup.freeze,
          metadata: Immutable.copy(values[:metadata] || {})
        ))
        raise ArgumentError, "ContextRequest call_sequence must be positive" unless call_sequence.positive?
        freeze
      end
    end
  end
end
