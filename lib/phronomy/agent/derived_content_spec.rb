# frozen_string_literal: true

module Phronomy
  module Agent
    DerivedContentSpec = Data.define(
      :content,
      :content_format,
      :category,
      :role,
      :coverage_candidate_ids,
      :source_record_ids,
      :source_content_refs,
      :transformer_id,
      :transformer_version,
      :metadata
    ) do
      def initialize(**values)
        super(**values.merge(
          content: Immutable.copy(values[:content]),
          content_format: values.fetch(:content_format).to_sym,
          category: values.fetch(:category).to_sym,
          role: values[:role]&.to_sym,
          coverage_candidate_ids: Array(values[:coverage_candidate_ids]).map(&:to_s).freeze,
          source_record_ids: Array(values[:source_record_ids]).map(&:to_s).freeze,
          source_content_refs: Array(values[:source_content_refs]).map(&:to_s).freeze,
          transformer_id: values.fetch(:transformer_id).to_s.freeze,
          transformer_version: Integer(values.fetch(:transformer_version)),
          metadata: Immutable.copy(values[:metadata] || {})
        ))
        freeze
      end
    end
  end
end
