# frozen_string_literal: true

module Phronomy
  module Agent
    ContextPolicyInput = Data.define(
      :agent_id,
      :execution_id,
      :call_sequence,
      :call_mode,
      :instruction,
      :knowledge,
      :tools,
      :conversation,
      :token_budget,
      :model_config,
      :previous_manifest,
      :metadata
    ) do
      def initialize(**values)
        normalized_instruction = Array(values[:instruction]).freeze
        normalized_knowledge = Array(values[:knowledge]).freeze
        normalized_tools = Array(values[:tools]).freeze
        normalized_conversation = Array(values[:conversation]).map do |group|
          normalized_group = Array(group).freeze
          raise ArgumentError, "ContextPolicyInput conversation groups must not be empty" if normalized_group.empty?
          normalized_group
        end.freeze

        validate_items!(normalized_instruction, ContextPolicyInput::InstructionItem, :instruction)
        validate_items!(normalized_knowledge, ContextPolicyInput::KnowledgeItem, :knowledge)
        validate_items!(normalized_tools, ContextPolicyInput::ToolItem, :tools)
        normalized_conversation.each do |group|
          validate_items!(group, ContextPolicyInput::ConversationItem, :conversation)
        end

        call_sequence = Integer(values.fetch(:call_sequence))
        raise ArgumentError, "ContextPolicyInput call_sequence must be positive" unless call_sequence.positive?

        call_mode = values.fetch(:call_mode).to_sym
        unless LLMInputManifest::CALL_MODES.include?(call_mode)
          raise ArgumentError, "unknown ContextPolicyInput call_mode: #{call_mode.inspect}"
        end

        super(**values.merge(
          agent_id: values.fetch(:agent_id).to_s.freeze,
          execution_id: values[:execution_id]&.to_s&.freeze,
          call_sequence: call_sequence,
          call_mode: call_mode,
          instruction: normalized_instruction,
          knowledge: normalized_knowledge,
          tools: normalized_tools,
          conversation: normalized_conversation,
          model_config: Immutable.copy(values[:model_config] || {}),
          metadata: Immutable.copy(values[:metadata] || {})
        ))
        freeze
      end

      private

      def validate_items!(items, expected_class, label)
        invalid = items.reject { |item| item.is_a?(expected_class) }
        return if invalid.empty?

        raise ArgumentError,
          "ContextPolicyInput #{label} contains #{invalid.first.class}; expected #{expected_class}"
      end
    end

    class ContextPolicyInput
      CONTENT_FORMATS = %i[text json].freeze
      DELIVERIES = %i[ask_argument chat_message].freeze
      FRAMEWORK_METADATA_KEYS = %w[
        phronomy_origin
        context_policy_origin
        context_policy_item_id
        context_policy_semantic_category
        context_policy_content_format
        context_policy_conversation_group_id
        handoff_policy_category
        handoff_provenance
        selection_candidate_id
        selection_unit_id
        selection_unit_kind
        journal_record_id
        source_agent_id
        source_execution_id
        llm_call_id
      ].freeze

      Provenance = Data.define(
        :origin,
        :content_ref,
        :record_id,
        :agent_id,
        :execution_id,
        :llm_call_id
      ) do
        def initialize(
          origin:,
          content_ref: nil,
          record_id: nil,
          agent_id: nil,
          execution_id: nil,
          llm_call_id: nil
        )
          super(
            origin: origin.to_sym,
            content_ref: content_ref&.to_s&.freeze,
            record_id: record_id&.to_s&.freeze,
            agent_id: agent_id&.to_s&.freeze,
            execution_id: execution_id&.to_s&.freeze,
            llm_call_id: llm_call_id&.to_s&.freeze
          )
          freeze
        end
      end

      InstructionItem = Data.define(
        :id, :kind, :role, :content, :content_format,
        :estimated_tokens, :required, :provenance, :metadata
      ) do
        def initialize(**values)
          super(**ContextPolicyInput.send(:normalize_content_item_values, values))
          freeze
        end

        def required? = required
      end

      KnowledgeItem = Data.define(
        :id, :kind, :role, :content, :content_format,
        :estimated_tokens, :required, :provenance, :metadata
      ) do
        def initialize(**values)
          super(**ContextPolicyInput.send(:normalize_content_item_values, values))
          freeze
        end

        def required? = required
      end

      ToolItem = Data.define(
        :id, :definition, :estimated_tokens, :required, :provenance, :metadata
      ) do
        def initialize(**values)
          provenance = ContextPolicyInput.send(:normalize_provenance, values[:provenance])
          definition = Immutable.copy(values.fetch(:definition))
          unless definition.is_a?(Hash) && definition["name"].to_s != ""
            raise ArgumentError, "ContextPolicyInput ToolItem definition requires a non-empty name"
          end

          super(
            id: values.fetch(:id).to_s.freeze,
            definition: definition,
            estimated_tokens: ContextPolicyInput.send(:normalize_estimated_tokens, values[:estimated_tokens]),
            required: !!values[:required],
            provenance: provenance,
            metadata: Immutable.copy(values[:metadata] || {})
          )
          raise ArgumentError, "ContextPolicyInput ToolItem id must not be empty" if id.empty?
          freeze
        end

        def required? = required
      end

      ConversationItem = Data.define(
        :id, :kind, :role, :content, :content_format,
        :sequence, :estimated_tokens, :required, :provenance,
        :tool_call_id, :tool_call_ids, :delivery, :metadata
      ) do
        def initialize(**values)
          normalized = ContextPolicyInput.send(:normalize_content_item_values, values)
          delivery = (values[:delivery] || :chat_message).to_sym
          unless ContextPolicyInput::DELIVERIES.include?(delivery)
            raise ArgumentError, "unknown ContextPolicyInput delivery: #{delivery.inspect}"
          end

          super(**normalized.merge(
            sequence: values[:sequence] && Integer(values[:sequence]),
            tool_call_id: values[:tool_call_id]&.to_s&.freeze,
            tool_call_ids: Array(values[:tool_call_ids]).compact.map(&:to_s).freeze,
            delivery: delivery
          ))
          freeze
        end

        def required? = required

        def with_required(required)
          return self if required? == !!required
          self.class.new(**to_h.merge(required: !!required))
        end
      end

      class << self
        private

        def normalize_content_item_values(values)
          id = values.fetch(:id).to_s.freeze
          raise ArgumentError, "ContextPolicyInput item id must not be empty" if id.empty?

          kind = values.fetch(:kind).to_sym
          role = values[:role]&.to_sym
          content_format = (values[:content_format] || infer_content_format(values[:content])).to_sym
          unless ContextPolicyInput::CONTENT_FORMATS.include?(content_format)
            raise ArgumentError, "unknown ContextPolicyInput content format: #{content_format.inspect}"
          end

          {
            id: id,
            kind: kind,
            role: role,
            content: Immutable.copy(values[:content]),
            content_format: content_format,
            estimated_tokens: normalize_estimated_tokens(values[:estimated_tokens]),
            required: !!values[:required],
            provenance: normalize_provenance(values[:provenance]),
            metadata: Immutable.copy(values[:metadata] || {})
          }
        end

        def infer_content_format(content)
          content.is_a?(String) ? :text : :json
        end

        def normalize_estimated_tokens(value)
          result = Integer(value || 0)
          raise ArgumentError, "estimated_tokens must be non-negative" if result.negative?
          result
        end

        def normalize_provenance(value)
          return value if value.is_a?(ContextPolicyInput::Provenance)
          return ContextPolicyInput::Provenance.new(origin: :unknown) if value.nil?
          return ContextPolicyInput::Provenance.new(**value) if value.is_a?(Hash)

          raise ArgumentError, "ContextPolicyInput item provenance must be Provenance or Hash"
        end
      end
    end
  end
end
