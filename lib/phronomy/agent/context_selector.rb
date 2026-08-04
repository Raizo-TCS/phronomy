# frozen_string_literal: true

module Phronomy
  module Agent
    # Selects prior Journal records for LLM context using token-budget-aware
    # atomic unit selection.
    #
    # An atomic unit is all records sharing the same execution_id — one completed
    # AgentExecution. Units are selected whole (never split) from most-recent first.
    class ContextSelector
      # Selects transcript records that fit within the available history budget.
      #
      # @param agent_root         [AgentRoot]
      # @param journal_projection [JournalProjection]
      # @param token_budget       [TokenBudget, nil]  nil → return all records
      # @param mandatory_bytes    [String, nil]       content whose token cost is
      #                                               already reserved from budget
      # @yieldparam content_ref  [Object]
      # @yieldreturn             [String]  raw content bytes for estimation
      # @return [Array<JournalRecord>]
      def select(agent_root:, journal_projection:, token_budget: nil, mandatory_bytes: nil)
        records = journal_projection.transcript_records
        return records unless token_budget

        mandatory_estimate = mandatory_bytes ? estimate(mandatory_bytes) : 0
        remaining = token_budget.available(used: mandatory_estimate)

        if remaining <= 0
          if mandatory_estimate > token_budget.effective_input_limit
            raise Phronomy::ContextBudgetExceededError,
              "Mandatory content (estimated #{mandatory_estimate} tokens) exceeds " \
              "available input budget (#{token_budget.effective_input_limit} tokens)"
          end
          # mandatory fits exactly; no room remains for optional history
          return []
        end

        groups = group_by_execution(records)
        selected_groups = []
        used = 0

        groups.reverse_each do |group|
          group_estimate = group.sum { |r| estimate(yield(r.content_ref)) }
          break if used + group_estimate > remaining
          selected_groups << group
          used += group_estimate
        end

        selected_groups.reverse.flatten
      end

      private

      def estimate(bytes)
        Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes)
      end

      # Groups records chronologically by execution_id, preserving arrival order.
      def group_by_execution(records)
        seen_order = []
        grouped = {}
        records.each do |record|
          eid = record.execution_id
          unless grouped.key?(eid)
            grouped[eid] = []
            seen_order << eid
          end
          grouped[eid] << record
        end
        seen_order.map { |eid| grouped[eid] }
      end
    end
  end
end
