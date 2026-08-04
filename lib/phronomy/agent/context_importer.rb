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
          records = Array(messages).flat_map do |message|
            import_message(message, system_message: system_message)
          end
          ImportedContext.new(records: records.freeze)
        end

        private

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
            [text_record(:external_message, :external, :user, read(message, :content))]
          when :assistant
            import_assistant(message)
          when :tool
            tool_call_id = read_optional(message, :tool_call_id)
            raise ArgumentError, "tool message requires tool_call_id" if tool_call_id.to_s.empty?

            [ImportedRecord.new(
              kind: :tool_result,
              channel: :tool,
              role: :tool,
              content: String(read(message, :content)),
              content_format: :text,
              metadata: {"tool_call_id" => tool_call_id.to_s}
            )]
          else
            raise ArgumentError, "unsupported message role: #{role.inspect}"
          end
        end

        def import_assistant(message)
          result = []
          content = read_optional(message, :content)
          unless content.nil? || content.to_s.empty?
            result << text_record(:llm_message, :llm, :assistant, content)
          end

          tool_calls = read_optional(message, :tool_calls)
          Array(tool_calls.respond_to?(:values) ? tool_calls.values : tool_calls).each do |call|
            payload = normalize(read_tool_call(call))
            call_id = payload.fetch("id").to_s
            result << ImportedRecord.new(
              kind: :tool_call,
              channel: :tool,
              role: :assistant,
              content: payload,
              content_format: :json,
              metadata: {
                "tool_call_id" => call_id,
                "tool_name" => payload.fetch("name").to_s
              }
            )
          end
          if result.empty?
            raise ArgumentError,
              "assistant message requires content or one or more tool_calls"
          end
          result
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
            arguments: read_optional(call, :arguments) || {}
          }
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
