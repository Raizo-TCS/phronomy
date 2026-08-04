# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextSelector
      def select(agent_root:, journal_projection:, token_budget: nil)
        records = journal_projection.transcript_records
        return records unless token_budget

        remaining = token_budget.available(used: 0)
        selected = []
        used = 0
        records.reverse_each do |record|
          bytes = yield(record.content_ref)
          estimate = Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes)
          break if used + estimate > remaining

          selected << record
          used += estimate
        end
        selected.reverse
      end
    end
  end
end
