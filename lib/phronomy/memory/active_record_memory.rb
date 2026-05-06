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
            JSON.generate(msg.tool_calls)
          end
          model_id = msg.model_id if msg.respond_to?(:model_id)

          @model_class.create!(
            thread_id:       thread_id,
            role:            msg.role.to_s,
            content:         msg.content.to_s,
            tool_calls_json: tool_calls_json,
            model_id:        model_id
          )
        end
      end

      # Deletes all messages for a thread.
      def clear(thread_id:)
        @model_class.where(thread_id: thread_id).delete_all
      end

      private

      def to_message_struct(record)
        tool_calls = record.tool_calls_json ? JSON.parse(record.tool_calls_json) : nil
        OpenStruct.new(
          role:       record.role.to_sym,
          content:    record.content,
          tool_calls: tool_calls,
          model_id:   record.respond_to?(:model_id) ? record.model_id : nil
        )
      end
    end
  end
end
