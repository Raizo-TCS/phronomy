# frozen_string_literal: true

module Phronomy
  module Agent
    # Materialized knowledge accepted by create(knowledge:) without internal DTOs.
    # @api public
    KnowledgeItem = Data.define(:content, :metadata) do
      def initialize(content:, metadata: {})
        super(content: String(content).dup.freeze, metadata: Phronomy::Values::Immutable.copy(metadata))
      end
    end
  end
end
