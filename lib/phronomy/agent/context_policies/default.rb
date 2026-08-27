# frozen_string_literal: true

module Phronomy
  module Agent
    module ContextPolicies
      class Default < ContextPolicy
        CONVERSATION_SHARE = 0.60

        def self.instance
          @instance ||= new.freeze
        end

        def call(input)
          unless input.is_a?(ContextPolicyInput)
            raise ArgumentError, "Default ContextPolicy expected ContextPolicyInput"
          end

          return all_context(input) unless input.token_budget

          limit = input.token_budget.effective_input_limit
          required_knowledge = input.knowledge.select(&:required?)
          optional_knowledge = input.knowledge.reject(&:required?)
          required_conversation = input.conversation.select { |group| group.any?(&:required?) }
          optional_conversation = input.conversation.reject { |group| group.any?(&:required?) }

          fixed_cost = item_cost(input.instruction) + item_cost(input.tools) +
            item_cost(required_knowledge) + group_cost(required_conversation)
          if fixed_cost > limit
            raise Phronomy::ContextBudgetExceededError,
              "Required Context (estimated #{fixed_cost} tokens) exceeds " \
              "available input budget (#{limit} tokens)"
          end

          remaining = limit - fixed_cost
          conversation_budget = (remaining * CONVERSATION_SHARE).floor
          knowledge_budget = remaining - conversation_budget

          selected_conversation, older_conversation, conversation_used =
            select_recent_suffix(optional_conversation, conversation_budget)
          selected_knowledge, remaining_knowledge, knowledge_used =
            select_stable_fit(optional_knowledge, knowledge_budget)

          reusable = remaining - conversation_used - knowledge_used
          if reusable.positive? && !older_conversation.empty?
            more_conversation, _, used =
              select_recent_suffix(older_conversation, reusable)
            selected_conversation = more_conversation + selected_conversation
            reusable -= used
          end
          if reusable.positive? && !remaining_knowledge.empty?
            more_knowledge, _remaining_knowledge, used =
              select_stable_fit(remaining_knowledge, reusable)
            selected_knowledge += more_knowledge
            reusable -= used
          end

          conversation = (required_conversation + selected_conversation)
            .uniq
            .sort_by { |group| group_sequence(group) }
          knowledge_ids = (required_knowledge + selected_knowledge).to_h { |item| [item.id, true] }
          knowledge = input.knowledge.select { |item| knowledge_ids[item.id] }

          plan(
            instruction: input.instruction,
            knowledge: knowledge,
            tools: input.tools,
            conversation: conversation,
            metadata: {
              "default_policy" => true,
              "estimated_fixed_tokens" => fixed_cost,
              "estimated_unused_tokens" => reusable
            }
          )
        end

        private

        def all_context(input)
          plan(
            instruction: input.instruction,
            knowledge: input.knowledge,
            tools: input.tools,
            conversation: input.conversation,
            metadata: {"default_policy" => true}
          )
        end

        def item_cost(items)
          Array(items).sum { |item| Integer(item.estimated_tokens || 0) }
        end

        def group_cost(groups)
          Array(groups).sum { |group| item_cost(group) }
        end

        def group_sequence(group)
          group.filter_map(&:sequence).min || 0
        end

        def select_recent_suffix(groups, budget)
          ordered = Array(groups).sort_by { |group| group_sequence(group) }
          selected = []
          remaining = Integer(budget)
          stop_index = -1

          (ordered.length - 1).downto(0) do |index|
            cost = item_cost(ordered[index])
            if cost > remaining
              stop_index = index
              break
            end
            selected.unshift(ordered[index])
            remaining -= cost
          end

          older = if stop_index >= 0
            ordered[0..stop_index]
          else
            []
          end
          [selected.freeze, older.freeze, Integer(budget) - remaining]
        end

        def select_stable_fit(items, budget)
          remaining = Integer(budget)
          selected = []
          unselected = []
          Array(items).each do |item|
            cost = Integer(item.estimated_tokens || 0)
            if cost <= remaining
              selected << item
              remaining -= cost
            else
              unselected << item
            end
          end
          [selected.freeze, unselected.freeze, Integer(budget) - remaining]
        end
      end
    end
  end
end
