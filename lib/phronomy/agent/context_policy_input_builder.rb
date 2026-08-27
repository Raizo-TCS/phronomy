# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextPolicyInputBuilder
      KNOWLEDGE_KINDS = %i[knowledge memory summary structured_state].freeze
      CONVERSATION_KINDS = %i[external_message assistant_message tool_message current_input current_request].freeze

      def initialize(content_loader:)
        @content_loader = content_loader
      end

      def build(
        agent_id:,
        execution_id:,
        call_sequence:,
        call_mode:,
        candidates:,
        instruction:,
        tools:,
        token_budget:, model_config:, previous_manifest:, current_input: nil,
        metadata: {}
      )
        instruction_items = Array(instruction).dup
        knowledge = []
        conversation = []

        Array(candidates).each do |candidate|
          case semantic_category(candidate.category)
          when :instruction
            instruction_items << instruction_item(candidate)
          when :knowledge
            knowledge << knowledge_item(candidate)
          when :conversation
            conversation << conversation_item(candidate)
          end
        end
        conversation << current_input if current_input

        groups = conversation_groups(
          conversation,
          execution_id: execution_id,
          call_mode: call_mode
        )

        ContextPolicyInput.new(
          agent_id: agent_id,
          execution_id: execution_id,
          call_sequence: call_sequence,
          call_mode: call_mode,
          instruction: instruction_items,
          knowledge: knowledge,
          tools: tools,
          conversation: groups,
          token_budget: token_budget,
          model_config: model_config,
          previous_manifest: previous_manifest,
          metadata: metadata
        )
      end

      private

      def semantic_category(kind)
        normalized = kind.to_sym
        return :instruction if normalized == :instruction || normalized == :handoff_responsibility
        return :knowledge if KNOWLEDGE_KINDS.include?(normalized)
        return :conversation if CONVERSATION_KINDS.include?(normalized)

        raise ArgumentError, "unsupported Context Policy candidate category: #{kind.inspect}"
      end

      def instruction_item(candidate)
        ContextPolicyInput::InstructionItem.new(
          **common_content_values(candidate),
          role: candidate.role || :system
        )
      end

      def knowledge_item(candidate)
        ContextPolicyInput::KnowledgeItem.new(
          **common_content_values(candidate),
          role: candidate.role || :user
        )
      end

      def conversation_item(candidate)
        values = common_content_values(candidate)
        ContextPolicyInput::ConversationItem.new(
          **values,
          role: candidate.role,
          sequence: candidate.sequence,
          tool_call_id: candidate.tool_call_id,
          tool_call_ids: canonical_tool_call_ids(candidate),
          delivery: :chat_message
        )
      end

      def common_content_values(candidate)
        format = content_format(candidate)
        {
          id: candidate.candidate_id,
          kind: candidate.category,
          content: load_content(candidate.content_ref, format),
          content_format: format,
          estimated_tokens: Integer(candidate.metadata["estimated_tokens"] || 0),
          required: candidate.constraint.required?,
          provenance: ContextPolicyInput::Provenance.new(
            origin: candidate.source_kind,
            content_ref: candidate.content_ref,
            record_id: candidate.record_id,
            agent_id: candidate.agent_id,
            execution_id: candidate.execution_id,
            llm_call_id: candidate.llm_call_id
          ),
          metadata: candidate.metadata
        }
      end

      def content_format(candidate)
        explicit = candidate.metadata["content_format"] || candidate.metadata[:content_format]
        return explicit.to_sym if explicit
        return :json if %i[assistant_message tool_message].include?(candidate.category.to_sym)

        :text
      end

      def load_content(content_ref, format)
        bytes = @content_loader.call(content_ref)
        return bytes if format == :text

        Phronomy::CanonicalJSON.load(bytes)
      end

      def conversation_groups(items, execution_id:, call_mode:)
        ordered = Array(items).sort_by { |item| [item.sequence || 0, item.id] }
        assistants = ordered.select { |item| item.kind == :assistant_message }
        tool_messages = ordered.select { |item| item.kind == :tool_message }
        tool_messages_by_id = tool_messages.group_by(&:tool_call_id)
        tool_messages_by_id.each do |tool_call_id, messages|
          if tool_call_id.nil? || tool_call_id.empty?
            raise ArgumentError, "Tool message Context item requires tool_call_id"
          end
          if messages.length > 1
            raise ArgumentError, "duplicate Tool message in Context Policy input: #{tool_call_id}"
          end
        end

        assistant_by_tool_call = {}
        assistants.each do |assistant|
          assistant.tool_call_ids.each do |tool_call_id|
            if assistant_by_tool_call.key?(tool_call_id)
              raise ArgumentError,
                "duplicate assistant Tool Call id in Context Policy input: #{tool_call_id}"
            end
            assistant_by_tool_call[tool_call_id] = assistant
          end
        end

        claimed = {}
        groups = []
        ordered.each do |item|
          next if claimed[item.id]

          if item.kind == :assistant_message && !item.tool_call_ids.empty?
            messages = item.tool_call_ids.map do |tool_call_id|
              tool_messages_by_id.fetch(tool_call_id) do
                raise ArgumentError,
                  "assistant Tool Call has no Tool message in Context Policy input: #{tool_call_id}"
              end.first
            end
            group = ([item] + messages).uniq.sort_by { |member| [member.sequence || 0, member.id] }
          elsif item.kind == :tool_message
            assistant = assistant_by_tool_call[item.tool_call_id]
            unless assistant
              raise ArgumentError,
                "orphan Tool message in Context Policy input: #{item.tool_call_id}"
            end
            next if claimed[assistant.id]
            group = ([assistant] + assistant.tool_call_ids.map do |tool_call_id|
              tool_messages_by_id.fetch(tool_call_id).first
            end).uniq.sort_by { |member| [member.sequence || 0, member.id] }
          else
            group = [item]
          end

          group.each { |member| claimed[member.id] = true }
          groups << group
        end

        mark_framework_required(groups, execution_id: execution_id, call_mode: call_mode)
      end

      def mark_framework_required(groups, execution_id:, call_mode:)
        return groups.map(&:freeze).freeze unless call_mode.to_sym == :complete

        current_request_ids = groups.flatten.select do |item|
          item.kind == :external_message &&
            item.provenance.origin == :working &&
            item.provenance.execution_id.to_s == execution_id.to_s
        end.map(&:id).to_h { |id| [id, true] }

        current_tool_groups = groups.select do |group|
          group.any? do |item|
            %i[assistant_message tool_message].include?(item.kind) &&
              item.provenance.origin == :working &&
              item.provenance.execution_id.to_s == execution_id.to_s
          end && group.any? { |item| item.kind == :tool_message }
        end
        latest_tool_group = current_tool_groups.max_by do |group|
          group.filter_map(&:sequence).max || 0
        end
        latest_tool_ids = Array(latest_tool_group).map(&:id).to_h { |id| [id, true] }

        groups.map do |group|
          group.map do |item|
            required = item.required? || current_request_ids[item.id] || latest_tool_ids[item.id]
            item.with_required(required)
          end.freeze
        end.freeze
      end

      def canonical_tool_call_ids(candidate)
        Array(candidate.metadata["tool_call_ids"] || candidate.metadata[:tool_call_ids])
          .compact
          .map(&:to_s)
      end
    end
  end
end
