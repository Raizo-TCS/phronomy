# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    class ContextPolicy
      def call(_input)
        raise NotImplementedError, "#{self.class}#call is not implemented"
      end

      protected

      def instruction_item(
        content:,
        role: :system,
        kind: :instruction,
        content_format: nil,
        required: false,
        metadata: {}
      )
        ContextPolicyInput::InstructionItem.new(
          id: generated_item_id(:instruction),
          kind: kind,
          role: role,
          content: content,
          content_format: content_format || inferred_content_format(content),
          estimated_tokens: estimate_content(content),
          required: required,
          provenance: generated_provenance,
          metadata: metadata
        )
      end

      def knowledge_item(
        content:,
        role: :user,
        kind: :knowledge,
        content_format: nil,
        required: false,
        metadata: {}
      )
        ContextPolicyInput::KnowledgeItem.new(
          id: generated_item_id(:knowledge),
          kind: kind,
          role: role,
          content: content,
          content_format: content_format || inferred_content_format(content),
          estimated_tokens: estimate_content(content),
          required: required,
          provenance: generated_provenance,
          metadata: metadata
        )
      end

      def conversation_item(
        content:,
        role:,
        kind: :conversation,
        content_format: nil,
        sequence: nil,
        required: false,
        tool_call_id: nil,
        tool_call_ids: [],
        delivery: :chat_message,
        metadata: {}
      )
        ContextPolicyInput::ConversationItem.new(
          id: generated_item_id(:conversation),
          kind: kind,
          role: role,
          content: content,
          content_format: content_format || inferred_content_format(content),
          sequence: sequence,
          estimated_tokens: estimate_content(content),
          required: required,
          provenance: generated_provenance,
          tool_call_id: tool_call_id,
          tool_call_ids: tool_call_ids,
          delivery: delivery,
          metadata: metadata
        )
      end

      def plan(
        instruction: [],
        knowledge: [],
        tools: [],
        conversation: [],
        metadata: {}
      )
        ContextPlan.new(
          instruction: instruction,
          knowledge: knowledge,
          tools: tools,
          conversation: conversation,
          metadata: metadata
        )
      end

      private

      def generated_item_id(category)
        "policy:#{category}:#{SecureRandom.uuid}".freeze
      end

      def generated_provenance
        ContextPolicyInput::Provenance.new(origin: :policy_generated)
      end

      def inferred_content_format(content)
        content.is_a?(String) ? :text : :json
      end

      def estimate_content(content)
        bytes = content.is_a?(String) ? content : Phronomy::CanonicalJSON.dump(content)
        Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes)
      end
    end
  end
end
