# frozen_string_literal: true

require "json"
require "ostruct"

module Phronomy
  module Memory
    # ActiveRecord-backed memory.
    # Persists conversation messages to a relational database.
    #
    # The model_class must respond to:
    #   .where(thread_id:).order(:created_at) — returns a collection of records
    #   .where(thread_id:).delete_all
    #   .create!(thread_id:, role:, content:, tool_calls_json:, model_id:)
    #
    # Each record must expose: #role, #content, #tool_calls_json, #model_id
    #
    # @example
    #   memory = Phronomy::Memory::ActiveRecordMemory.new(
    #     model_class: PhronomyMessage
    #   )
    class ActiveRecordMemory < Base
      # @param model_class [Class] ActiveRecord model with the phronomy_messages schema.
      def initialize(model_class:)
        @model_class = model_class
      end

      # Loads all stored messages for a thread, ordered by creation time.
      # @param thread_id [String]
      # @param limit [Integer, nil] optional cap on number of messages returned (most recent)
      # @return [Array<OpenStruct>] message-like objects with :role, :content, :tool_calls
      def load_messages(thread_id:, limit: nil, **)
        scope = @model_class.where(thread_id: thread_id).order(:created_at)
        records = scope.to_a
        records = records.last(limit) if limit
        records.map { |r| to_message_struct(r) }
      end

      # Replaces all stored messages for a thread with the provided list.
      # @param thread_id [String]
      # @param messages [Array] objects responding to #role, #content, #tool_calls (optional), #model_id (optional)
      def save_messages(thread_id:, messages:)
        @model_class.where(thread_id: thread_id).delete_all
        messages.each do |msg|
          tool_calls_json = if msg.respond_to?(:tool_calls) && msg.tool_calls
            serializable = case msg.tool_calls
            when Hash
              msg.tool_calls.transform_values { |tc| tc.respond_to?(:to_h) ? tc.to_h : tc }
            when Array
              msg.tool_calls.map { |tc| tc.respond_to?(:to_h) ? tc.to_h : tc }
            else
              msg.tool_calls
            end
            JSON.generate(serializable)
          end
          model_id = msg.model_id if msg.respond_to?(:model_id)

          @model_class.create!(
            thread_id: thread_id,
            role: msg.role.to_s,
            content: msg.content.to_s,
            tool_calls_json: tool_calls_json,
            model_id: model_id
          )
        end
      end

      # Deletes all messages for a thread.
      def clear(thread_id:)
        @model_class.where(thread_id: thread_id).delete_all
      end

      private

      def to_message_struct(record)
        tool_calls = if record.tool_calls_json
          parsed = JSON.parse(record.tool_calls_json)
          case parsed
          when Hash
            parsed.transform_values { |tc| restore_tool_call(tc) }
          when Array
            parsed.map { |tc| restore_tool_call(tc) }
          else
            parsed
          end
        end
        OpenStruct.new(
          role: record.role.to_sym,
          content: record.content,
          tool_calls: tool_calls,
          model_id: record.respond_to?(:model_id) ? record.model_id : nil
        )
      end

      def restore_tool_call(tc)
        return tc unless tc.is_a?(Hash) && tc["id"] && tc["name"]
        RubyLLM::ToolCall.new(
          id: tc["id"],
          name: tc["name"],
          arguments: tc["arguments"] || {}
        )
      end
    end
  end
end
