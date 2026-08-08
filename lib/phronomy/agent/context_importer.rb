# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextImporter
      ImportedRecord = Data.define(
        :kind, :channel, :role, :content, :content_format, :metadata
      ) do
        def initialize(**values)
          super(**values.merge(
            content: Immutable.copy(values[:content]),
            metadata: Immutable.copy(values[:metadata] || {})
          ))
          freeze
        end
      end

      ImportedContext = Data.define(:records) do
        def initialize(records:)
          super(records: records.freeze)
          freeze
        end
      end

      class << self
        def import_messages(messages, system_message: :reject)
          source_messages = Array(messages)
          validate_protocol!(source_messages)
          records = source_messages.map do |message|
            import_message(message, system_message: system_message)
          end
          ImportedContext.new(records: records.freeze)
        end

        private

        # Import validation is defined by the external-message contract, not by
        # limitations of Phronomy's internal representation. Each supplied
        # message is one explicit logical message and is journaled without
        # splitting its assistant content from its Tool Calls.
        def validate_protocol!(messages)
          pending = {}
          seen_tool_call_ids = {}

          messages.each_with_index do |message, index|
            role = read(message, :role).to_sym

            if pending.any? && role != :tool
              raise ArgumentError,
                "message #{index} appears before Tool Results for: #{pending.keys.join(', ')}"
            end

            case role
            when :assistant
              tool_calls_for(message).each do |call|
                payload = normalize(read_tool_call(call))
                call_id = payload.fetch("id").to_s
                raise ArgumentError, "tool_call requires id" if call_id.empty?
                if seen_tool_call_ids[call_id]
                  raise ArgumentError, "duplicate tool_call id: #{call_id}"
                end
                seen_tool_call_ids[call_id] = true
                pending[call_id] = true
              end
            when :tool
              call_id = read_optional(message, :tool_call_id).to_s
              raise ArgumentError, "tool message requires tool_call_id" if call_id.empty?
              unless pending.delete(call_id)
                raise ArgumentError, "orphan or duplicate Tool Result: #{call_id}"
              end
            when :user, :system
              # No Tool protocol state is introduced by these roles.
            else
              raise ArgumentError, "unsupported message role: #{role.inspect}"
            end
          end

          return if pending.empty?

          raise ArgumentError,
            "imported history ends before Tool Results for: #{pending.keys.join(', ')}"
        end

        def import_message(message, system_message:)
          role = read(message, :role).to_sym
          attachments = read_optional(message, :attachments)
          if attachments && !Array(attachments).empty?
            raise ArgumentError,
              "message attachments require an explicit attachment importer"
          end

          case role
          when :system
            if system_message == :reject
              raise ArgumentError,
                "system messages must be imported as explicit instruction segments"
            end
            raise ArgumentError,
              "unsupported system_message policy: #{system_message.inspect}"
          when :user
            text_record(:external_message, :external, :user, read(message, :content))
          when :assistant
            import_assistant(message)
          when :tool
            import_tool_message(message)
          else
            raise ArgumentError, "unsupported message role: #{role.inspect}"
          end
        end

        def import_assistant(message)
          calls = tool_calls_for(message).map { |call| normalize(read_tool_call(call)) }
          content = read_optional(message, :content)
          content = "" if content.nil? && !calls.empty?
          if (content.nil? || (content.respond_to?(:empty?) && content.empty?)) && calls.empty?
            raise ArgumentError,
              "assistant message requires content or one or more tool_calls"
          end

          payload = {
            "role" => "assistant",
            "content" => normalize(content),
            "tool_calls" => calls
          }
          model_id = read_optional(message, :model_id)
          payload["model_id"] = model_id.to_s if model_id

          ImportedRecord.new(
            kind: :assistant_message,
            channel: :llm,
            role: :assistant,
            content: payload,
            content_format: :json,
            metadata: assistant_metadata(calls)
          )
        end

        def import_tool_message(message)
          tool_call_id = read_optional(message, :tool_call_id).to_s
          raise ArgumentError, "tool message requires tool_call_id" if tool_call_id.empty?

          ImportedRecord.new(
            kind: :tool_message,
            channel: :tool,
            role: :tool,
            content: {
              "role" => "tool",
              "content" => String(read(message, :content)),
              "tool_call_id" => tool_call_id
            },
            content_format: :json,
            metadata: {"tool_call_id" => tool_call_id}
          )
        end

        def assistant_metadata(calls)
          {
            "tool_call_ids" => calls.map { |call| call.fetch("id").to_s },
            "tool_names" => calls.map { |call| call.fetch("name").to_s }
          }
        end

        def tool_calls_for(message)
          tool_calls = read_optional(message, :tool_calls)
          Array(tool_calls.respond_to?(:values) ? tool_calls.values : tool_calls)
        end

        def text_record(kind, channel, role, content)
          ImportedRecord.new(
            kind: kind,
            channel: channel,
            role: role,
            content: String(content),
            content_format: :text,
            metadata: {}
          )
        end

        def read_tool_call(call)
          return call.to_h if call.respond_to?(:to_h)

          {
            id: read(call, :id),
            name: read(call, :name),
            arguments: read_optional(call, :arguments) || {},
            thought_signature: read_optional(call, :thought_signature)
          }.compact
        end

        def read(value, name)
          result = read_optional(value, name)
          raise ArgumentError, "message is missing #{name}" if result.nil?

          result
        end

        def read_optional(value, name)
          return value.public_send(name) if value.respond_to?(name)
          return value[name] if value.respond_to?(:key?) && value.key?(name)
          return value[name.to_s] if value.respond_to?(:key?) && value.key?(name.to_s)

          nil
        end

        def normalize(value)
          case value
          when Hash
            value.to_h { |key, child| [key.to_s, normalize(child)] }
          when Array
            value.map { |child| normalize(child) }
          when Symbol
            value.to_s
          when String, Integer, Float, TrueClass, FalseClass, NilClass
            value
          else
            value.respond_to?(:to_h) ? normalize(value.to_h) :
              raise(ArgumentError, "unsupported imported value: #{value.class}")
          end
        end
      end
    end
  end
end
