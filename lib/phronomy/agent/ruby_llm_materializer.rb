# frozen_string_literal: true

module Phronomy
  module Agent
    class RubyLLMMaterializer
      RuntimeProjection = Data.define(
        :system, :messages, :tool_classes, :ask_message,
        :model_config, :manifest, :manifest_ref
      )

      def initialize(agent:, persistence:)
        @agent = agent
        @persistence = persistence
      end

      def materialize(manifest:, manifest_ref:)
        verify_manifest_identity!(manifest, manifest_ref)
        verify_adapter!(manifest)
        tool_set = verify_tool_definitions!(manifest)
        model_config = fetch_json(manifest.model_config_ref)
        system_parts = []
        messages = []
        ask_message = nil

        manifest.segments.each do |segment|
          case segment.delivery
          when :ask_argument
            ask_message = @persistence.contents.fetch_text(segment.content_ref)
          when :chat_message
            if segment.role == :system
              system_parts << @persistence.contents.fetch_text(segment.content_ref)
            else
              messages << materialize_segment(segment)
            end
          else
            raise ArgumentError, "unknown manifest delivery: #{segment.delivery.inspect}"
          end
        end

        RuntimeProjection.new(
          system: system_parts.empty? ? nil : system_parts.join("\n\n"),
          messages: messages.freeze,
          tool_classes: tool_set.runtime_tools,
          ask_message: ask_message,
          model_config: Immutable.copy(model_config),
          manifest: manifest,
          manifest_ref: manifest_ref
        )
      end

      def materialize_journal_record(record)
        segment = LLMInputManifest::Segment.new(
          position: 0,
          category: record.kind,
          role: record.role,
          content_ref: record.content_ref,
          delivery: :chat_message,
          tool_call_id: record.metadata["tool_call_id"] || record.metadata[:tool_call_id],
          metadata: record.metadata
        )
        materialize_segment(segment)
      end

      private

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
        tool_set = ToolDefinitionSet.build(@agent)
        return tool_set unless manifest.tool_definitions_ref

        expected = @persistence.contents.fetch(manifest.tool_definitions_ref)
        actual = Phronomy::CanonicalJSON.dump(tool_set.definitions)
        unless expected == actual
          raise Phronomy::ConfigurationError,
            "Agent tool definitions changed after manifest creation"
        end
        tool_set
      end

      def fetch_json(content_ref)
        Phronomy::CanonicalJSON.load(@persistence.contents.fetch(content_ref))
      end

      def materialize_segment(segment)
        case segment.category.to_sym
        when :tool_call
          payload = fetch_json(segment.content_ref)
          tool_call_id = payload.fetch("id").to_s
          tool_call = RubyLLM::ToolCall.new(
            id: tool_call_id,
            name: payload.fetch("name"),
            arguments: payload.fetch("arguments", {}),
            thought_signature: payload["thought_signature"]
          )
          RubyLLM::Message.new(
            role: :assistant,
            content: "",
            tool_calls: {tool_call_id => tool_call}
          )
        when :tool_result
          RubyLLM::Message.new(
            role: :tool,
            content: @persistence.contents.fetch_text(segment.content_ref),
            tool_call_id: segment.tool_call_id ||
              segment.metadata["tool_call_id"] || segment.metadata[:tool_call_id]
          )
        else
          RubyLLM::Message.new(
            role: segment.role,
            content: @persistence.contents.fetch_text(segment.content_ref),
            tool_call_id: segment.tool_call_id
          )
        end
      end
    end

  end
end
