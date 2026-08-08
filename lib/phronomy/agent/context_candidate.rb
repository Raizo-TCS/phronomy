# frozen_string_literal: true

module Phronomy
  module Agent
    ContextCandidate = Data.define(
      :candidate_id,
      :source_kind,
      :category,
      :role,
      :content_ref,
      :record_id,
      :agent_id,
      :execution_id,
      :llm_call_id,
      :tool_call_id,
      :sequence,
      :requirement,
      :priority,
      :metadata
    ) do
      def initialize(**values)
        normalized = values.merge(
          candidate_id: values.fetch(:candidate_id).to_s.freeze,
          source_kind: values.fetch(:source_kind).to_sym,
          category: values.fetch(:category).to_sym,
          role: values[:role]&.to_sym,
          content_ref: values.fetch(:content_ref).to_s.freeze,
          record_id: values[:record_id]&.to_s&.freeze,
          agent_id: values[:agent_id]&.to_s&.freeze,
          execution_id: values[:execution_id]&.to_s&.freeze,
          llm_call_id: values[:llm_call_id]&.to_s&.freeze,
          tool_call_id: values[:tool_call_id]&.to_s&.freeze,
          sequence: values[:sequence] && Integer(values[:sequence]),
          requirement: (values[:requirement] || :optional).to_sym,
          priority: Integer(values[:priority] || 0),
          metadata: Immutable.copy(values[:metadata] || {})
        )
        unless %i[protocol_required declared_required optional].include?(normalized[:requirement])
          raise ArgumentError, "unknown ContextCandidate requirement: #{normalized[:requirement].inspect}"
        end

        super(**normalized)
        freeze
      end
    end
  end
end
