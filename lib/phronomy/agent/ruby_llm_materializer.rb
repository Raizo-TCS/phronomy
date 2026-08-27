# frozen_string_literal: true

module Phronomy
  module Agent
    class RubyLLMMaterializer
      RuntimeProjection = Data.define(
        :system, :messages, :tool_classes, :ask_message,
        :model_config, :manifest, :manifest_ref
      )

      def initialize(agent:, persistence:, additional_tools: [])
        @agent = agent
        @persistence = persistence
        @additional_tools = Array(additional_tools).freeze
      end

      def materialize(manifest:, manifest_ref:)
        verify_manifest_identity!(manifest, manifest_ref)
        verify_adapter!(manifest)
        tool_set = verify_tool_definitions!(manifest)
        model_config = fetch_json(manifest.model_config_ref)
        system_parts = []
        message_segments = []
        ask_message = nil

        manifest.segments.each do |segment|
          case segment.delivery
          when :ask_argument
            ask_message = @persistence.contents.fetch_text(segment.content_ref)
          when :chat_message
            if segment.role == :system
              system_parts << @persistence.contents.fetch_text(segment.content_ref)
            else
              message_segments << segment
            end
          else
            raise ArgumentError, "unknown manifest delivery: #{segment.delivery.inspect}"
          end
        end

        RuntimeProjection.new(
          system: system_parts.empty? ? nil : system_parts.join("\n\n"),
          messages: materialize_message_segments(message_segments).freeze,
          tool_classes: tool_set.runtime_tools,
          ask_message: ask_message,
          model_config: Immutable.copy(model_config),
          manifest: manifest,
          manifest_ref: manifest_ref
        )
      end

      def materialize_journal_record(record)
        materialize_segment(segment_from_record(record))
      end

      def materialize_journal_records(records)
        segments = Array(records).each_with_index.map do |record, index|
          segment_from_record(record, position: index)
        end
        materialize_message_segments(segments).freeze
      end

      private

      def segment_from_record(record, position: 0)
        LLMInputManifest::Segment.new(
          position: position,
          category: record.kind,
          role: record.role,
          content_ref: record.content_ref,
          delivery: :chat_message,
          tool_call_id: record.metadata["tool_call_id"] || record.metadata[:tool_call_id],
          metadata: record.metadata.merge(
            "journal_record_id" => record.record_id,
            "journal_sequence" => record.sequence,
            "llm_call_id" => record.llm_call_id
          ).compact
        )
      end

      def verify_manifest_identity!(manifest, manifest_ref)
        expected = @persistence.contents.fetch(manifest_ref)
        actual = Phronomy::CanonicalJSON.dump(manifest.to_h)
        return if expected == actual

        raise Phronomy::ContentStore::IntegrityError,
          "manifest content does not match manifest_ref: #{manifest_ref}"
      end

      def verify_adapter!(manifest)
        actual = Phronomy.configuration.llm_adapter.class.name
        return if manifest.adapter_name.nil? || manifest.adapter_name == actual

        raise Phronomy::ConfigurationError,
          "LLM adapter changed after manifest creation: #{manifest.adapter_name} -> #{actual}"
      end

      def verify_tool_definitions!(manifest)
        unless manifest.tool_definitions_ref
          return ToolDefinitionSet.build(
            @agent,
            additional_tools: @additional_tools
          )
        end

        expected_definitions = fetch_json(manifest.tool_definitions_ref)
        additional = @additional_tools
        if additional.empty? && defined?(Phronomy::MultiAgent::HandoffCapabilityFactory)
          ordinary_names = ToolDefinitionSet.build(@agent).definitions
            .map { |definition| definition.fetch("name") }
          additional = Array(expected_definitions).filter_map do |definition|
            name = definition.fetch("name")
            next if ordinary_names.include?(name)
            Phronomy::MultiAgent::HandoffCapabilityFactory.lookup(name)&.tool_class
          end
        end

        ToolDefinitionSet.build(@agent, additional_tools: additional)
          .select_definitions(expected_definitions)
      end

      def fetch_json(content_ref)
        Phronomy::CanonicalJSON.load(@persistence.contents.fetch(content_ref))
      end

      def materialize_message_segments(segments)
        segments.map { |segment| materialize_segment(segment) }
      end

      def materialize_segment(segment)
        case segment.category.to_sym
        when :assistant_message
          materialize_canonical_message(segment, expected_role: :assistant)
        when :tool_message
          materialize_canonical_message(segment, expected_role: :tool)
        when :tool_result
          raise ArgumentError, "raw Tool result is not an LLM message"
        else
          RubyLLM::Message.new(
            role: segment.role,
            content: @persistence.contents.fetch_text(segment.content_ref),
            tool_call_id: segment.tool_call_id
          )
        end
      end

      def materialize_canonical_message(segment, expected_role:)
        payload = fetch_json(segment.content_ref)
        role = payload.fetch("role").to_sym
        unless role == expected_role
          raise ArgumentError,
            "canonical #{segment.category} role mismatch: #{role.inspect}"
        end
        if segment.role && segment.role.to_sym != role
          raise ArgumentError,
            "manifest role does not match canonical message: #{segment.role.inspect} != #{role.inspect}"
        end

        tool_calls = materialize_tool_calls(payload["tool_calls"])
        message = RubyLLM::Message.new(
          role: role,
          content: initial_content_for(role, payload.fetch("content", nil), tool_calls),
          tool_calls: tool_calls.empty? ? nil : tool_calls,
          tool_call_id: payload["tool_call_id"],
          model_id: payload["model_id"]
        )

        message.content = payload["content"] if payload.key?("content")
        message
      end

      def initial_content_for(role, content, tool_calls)
        return "" if role == :assistant && content.nil? && !tool_calls.empty?

        content.nil? ? "" : content
      end

      def materialize_tool_calls(payloads)
        Array(payloads).each_with_object({}) do |payload, result|
          tool_call_id = payload.fetch("id").to_s
          if result.key?(tool_call_id)
            raise ArgumentError, "duplicate Tool Call in assistant message: #{tool_call_id}"
          end
          result[tool_call_id] = materialize_tool_call(payload)
        end
      end

      def materialize_tool_call(payload)
        RubyLLM::ToolCall.new(
          id: payload.fetch("id").to_s,
          name: payload.fetch("name"),
          arguments: payload.fetch("arguments", {}),
          thought_signature: payload["thought_signature"]
        )
      end
    end
  end
end
