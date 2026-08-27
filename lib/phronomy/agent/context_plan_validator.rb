# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextPlanValidator
      def validate!(input:, plan:)
        unless input.is_a?(ContextPolicyInput)
          raise ArgumentError, "ContextPlanValidator expected ContextPolicyInput"
        end
        unless plan.is_a?(ContextPlan)
          raise ArgumentError, "Context Policy returned #{plan.class}, expected #{ContextPlan}"
        end

        validate_flat_category!(
          input: input.instruction,
          output: plan.instruction,
          item_class: ContextPolicyInput::InstructionItem,
          label: :instruction,
          generated_allowed: true
        )
        validate_flat_category!(
          input: input.knowledge,
          output: plan.knowledge,
          item_class: ContextPolicyInput::KnowledgeItem,
          label: :knowledge,
          generated_allowed: true
        )
        validate_flat_category!(
          input: input.tools,
          output: plan.tools,
          item_class: ContextPolicyInput::ToolItem,
          label: :tools,
          generated_allowed: false
        )
        validate_conversation!(input.conversation, plan.conversation)
        validate_unique_ids!(plan)
        plan
      end

      private

      def validate_flat_category!(input:, output:, item_class:, label:, generated_allowed:)
        input_by_id = input.to_h { |item| [item.id, item] }
        output.each do |item|
          unless item.is_a?(item_class)
            raise ArgumentError,
              "ContextPlan #{label} contains #{item.class}; expected #{item_class}"
          end

          source = input_by_id[item.id]
          if source
            unless source == item
              raise ArgumentError, "ContextPlan modified input item #{item.id.inspect} in #{label}"
            end
          elsif !generated_allowed || item.provenance.origin != :policy_generated
            raise ArgumentError, "ContextPlan contains unknown #{label} item: #{item.id.inspect}"
          end
        end

        missing = input.select(&:required?).reject do |required|
          output.any? { |item| item.id == required.id }
        end
        return if missing.empty?

        raise Phronomy::ContextBudgetExceededError,
          "ContextPlan omitted required #{label} item(s): #{missing.map(&:id).inspect}"
      end

      def validate_conversation!(input_groups, output_groups)
        input_by_group_ids = input_groups.to_h do |group|
          [group.map(&:id), group]
        end
        selected_input_ids = {}

        output_groups.each do |group|
          unless group.is_a?(Array) && !group.empty?
            raise ArgumentError, "ContextPlan conversation groups must be non-empty Arrays"
          end
          unless group.all? { |item| item.is_a?(ContextPolicyInput::ConversationItem) }
            raise ArgumentError, "ContextPlan conversation group contains a non-ConversationItem"
          end

          ids = group.map(&:id)
          matching = input_by_group_ids[ids]
          if matching
            unless matching == group
              raise ArgumentError, "ContextPlan modified an input conversation group: #{ids.inspect}"
            end
            ids.each { |id| selected_input_ids[id] = true }
            next
          end

          overlaps = ids.any? do |id|
            input_groups.any? { |input_group| input_group.any? { |item| item.id == id } }
          end
          if overlaps
            raise ArgumentError,
              "ContextPlan split, merged, or reordered an input conversation group: #{ids.inspect}"
          end
          unless group.all? { |item| item.provenance.origin == :policy_generated }
            raise ArgumentError, "ContextPlan contains unknown conversation item(s): #{ids.inspect}"
          end
          validate_generated_conversation_group!(group)
        end

        missing_groups = input_groups.select do |group|
          group.any?(&:required?) && group.none? { |item| selected_input_ids[item.id] }
        end
        return if missing_groups.empty?

        raise Phronomy::ContextBudgetExceededError,
          "ContextPlan omitted required conversation group(s): " \
          "#{missing_groups.map { |group| group.map(&:id) }.inspect}"
      end

      def validate_generated_conversation_group!(group)
        assistants = group.select { |item| item.kind == :assistant_message }
        tools = group.select { |item| item.kind == :tool_message }
        tool_by_id = tools.group_by(&:tool_call_id)

        tool_by_id.each do |tool_call_id, messages|
          if tool_call_id.nil? || tool_call_id.empty? || messages.length != 1
            raise ArgumentError,
              "Policy-generated conversation group has invalid Tool message dependency"
          end
        end

        assistant_by_call = {}
        assistants.each do |assistant|
          assistant.tool_call_ids.each do |tool_call_id|
            if assistant_by_call.key?(tool_call_id)
              raise ArgumentError,
                "Policy-generated conversation group has duplicate assistant Tool Call: #{tool_call_id}"
            end
            assistant_by_call[tool_call_id] = assistant
            unless tool_by_id.key?(tool_call_id)
              raise ArgumentError,
                "Policy-generated assistant Tool Call has no Tool message: #{tool_call_id}"
            end
          end
        end

        tools.each do |tool|
          unless assistant_by_call.key?(tool.tool_call_id)
            raise ArgumentError,
              "Policy-generated conversation group contains orphan Tool message: #{tool.tool_call_id}"
          end
        end
      end

      def validate_unique_ids!(plan)
        ids = plan.instruction.map(&:id) + plan.knowledge.map(&:id) + plan.tools.map(&:id) +
          plan.conversation.flatten.map(&:id)
        duplicates = ids.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
        return if duplicates.empty?

        raise ArgumentError, "ContextPlan contains duplicate item IDs: #{duplicates.inspect}"
      end
    end
  end
end
