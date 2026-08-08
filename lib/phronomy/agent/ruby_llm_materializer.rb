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

      def materialize_message_segments(segments)
        result = []
        index = 0
        while index < segments.length
          segment = segments[index]
          if assistant_segment?(segment)
            grouped, consumed = assistant_group(segments, index)
            result << materialize_assistant_group(grouped)
            index += consumed
          else
            result << materialize_segment(segment)
            index += 1
          end
        end
        result
      end

      def assistant_segment?(segment)
        segment.role&.to_sym == :assistant &&
          %i[llm_message tool_call].include?(segment.category.to_sym)
      end

      def assistant_group(segments, start_index)
        first = segments.fetch(start_index)
        llm_call_id = metadata_value(first, "llm_call_id")
        return runtime_assistant_group(segments, start_index, llm_call_id) if llm_call_id

        import_assistant_group(segments, start_index)
      end

      def runtime_assistant_group(segments, start_index, llm_call_id)
        group = []
        index = start_index
        while (segment = segments[index]) && assistant_segment?(segment) &&
            metadata_value(segment, "llm_call_id").to_s == llm_call_id.to_s
          group << segment
          index += 1
        end
        [group, group.length]
      end

      def import_assistant_group(segments, start_index)
        first = segments.fetch(start_index)
        group = [first]
        index = start_index + 1
        last = first

        while (segment = segments[index]) && assistant_segment?(segment)
          break unless segment.category.to_sym == :tool_call
          break unless contiguous_source?(last, segment)
          break if metadata_value(segment, "llm_call_id")

          group << segment
          last = segment
          index += 1
        end
        [group, group.length]
      end

      def contiguous_source?(left, right)
        left_sequence = metadata_value(left, "journal_sequence")
        right_sequence = metadata_value(right, "journal_sequence")
        return false unless left_sequence && right_sequence

        Integer(right_sequence) == Integer(left_sequence) + 1
      end

      def materialize_assistant_group(segments)
        content_segments = segments.select { |segment| segment.category.to_sym == :llm_message }
        if content_segments.length > 1
          raise ArgumentError, "ambiguous assistant message group contains multiple content records"
        end

        tool_calls = {}
        segments.select { |segment| segment.category.to_sym == :tool_call }.each do |segment|
          payload = fetch_json(segment.content_ref)
          tool_call_id = payload.fetch("id").to_s
          if tool_calls.key?(tool_call_id)
            raise ArgumentError, "duplicate Tool Call in assistant message: #{tool_call_id}"
          end
          tool_calls[tool_call_id] = RubyLLM::ToolCall.new(
            id: tool_call_id,
            name: payload.fetch("name"),
            arguments: payload.fetch("arguments", {}),
            thought_signature: payload["thought_signature"]
          )
        end

        content = if content_segments.empty?
          ""
        else
          @persistence.contents.fetch_text(content_segments.first.content_ref)
        end

        RubyLLM::Message.new(
          role: :assistant,
          content: content,
          tool_calls: tool_calls.empty? ? nil : tool_calls
        )
      end

      def materialize_segment(segment)
        case segment.category.to_sym
        when :tool_call
          materialize_assistant_group([segment])
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

      def metadata_value(segment, name)
        segment.metadata[name] || segment.metadata[name.to_sym]
      end
    end
  end
end
