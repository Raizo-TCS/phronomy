# frozen_string_literal: true

module Phronomy
  module Agent
    ContextSelectionUnit = Data.define(
      :unit_id,
      :candidate_ids,
      :dependency_unit_ids,
      :kind,
      :requirement,
      :priority,
      :sequence_range,
      :metadata
    ) do
      def initialize(**values)
        normalized = values.merge(
          unit_id: values.fetch(:unit_id).to_s.freeze,
          candidate_ids: Array(values[:candidate_ids]).map(&:to_s).freeze,
          dependency_unit_ids: Array(values[:dependency_unit_ids]).map(&:to_s).freeze,
          kind: values.fetch(:kind).to_sym,
          requirement: (values[:requirement] || :optional).to_sym,
          priority: Integer(values[:priority] || 0),
          sequence_range: Array(values[:sequence_range]).map { |v| Integer(v) }.freeze,
          metadata: Immutable.copy(values[:metadata] || {})
        )
        unless %i[protocol_required declared_required optional].include?(normalized[:requirement])
          raise ArgumentError, "unknown ContextSelectionUnit requirement: #{normalized[:requirement].inspect}"
        end
        unless normalized[:sequence_range].length == 2
          raise ArgumentError, "ContextSelectionUnit sequence_range must contain two integers"
        end

        super(**normalized)
        freeze
      end
    end
  end
end
