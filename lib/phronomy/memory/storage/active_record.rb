# frozen_string_literal: true

require "json"

module Phronomy
  module Memory
    module Storage
      # ActiveRecord-backed storage for conversation messages.
      # Persists messages to a relational database via user-supplied AR model classes.
      #
      # The message model_class must respond to:
      #   .where(thread_id:).order(:created_at) — returns a collection of records
      #   .where(thread_id:).delete_all
      #   .create!(thread_id:, role:, content:, tool_calls_json:, model_id:)
      # Each record must expose: #role, #content, #tool_calls_json, #model_id
      #
      # The raw_model_class (optional) must respond to:
      #   .where(thread_id:).order(:seq) — returns records in seq order
      #   .where(thread_id:).delete_all
      #   .create!(thread_id:, seq:, role:, content:, tool_calls_json:, model_id:)
      # Each record must expose: #seq, #role, #content, #tool_calls_json, #model_id
      #
      # The compaction_model_class (optional) must respond to:
      #   .where(thread_id:).order(:start_seq)
      #   .where(thread_id:).delete_all
      #   .create!(thread_id:, start_seq:, end_seq:, summary_text:)
      # Each record must expose: #start_seq, #end_seq, #summary_text
      #
      # When raw_model_class or compaction_model_class are nil, the corresponding
      # operations raise NotImplementedError — use InMemory storage if you do not
      # need full raw/compaction persistence.
      #
      # @example
      #   storage = Phronomy::Memory::Storage::ActiveRecord.new(
      #     model_class:            PhronomyMessage,
      #     raw_model_class:        PhronomyRawMessage,
      #     compaction_model_class: PhronomyCompaction
      #   )
      #   manager = Phronomy::Memory::ConversationManager.new(storage: storage, ...)
      # Internal value object representing a loaded message record.
      MessageStruct = Data.define(:role, :content, :tool_calls, :model_id)
      private_constant :MessageStruct

      class ActiveRecord < Base
        # @param model_class            [Class]      AR model for the legacy load/save interface
        # @param raw_model_class        [Class, nil] AR model for raw message storage
        # @param compaction_model_class [Class, nil] AR model for compaction records
        def initialize(model_class:, raw_model_class: nil, compaction_model_class: nil)
          @model_class = model_class
          @raw_model_class = raw_model_class
          @compaction_model_class = compaction_model_class
        end

        # -----------------------------------------------------------------------
        # Legacy interface
        # -----------------------------------------------------------------------

        # Load all messages for a thread, ordered by creation time.
        #
        # @param thread_id [String]
        # @return [Array<MessageStruct>]
        def load(thread_id:)
          records = @model_class.where(thread_id: thread_id).order(:created_at).to_a
          records.map { |r| to_message_struct(r) }
        end

        # Replace all stored messages for a thread.
        #
        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          @model_class.transaction do
            @model_class.where(thread_id: thread_id).delete_all
            messages.each do |msg|
              @model_class.create!(
                thread_id: thread_id,
                role: msg.role.to_s,
                content: msg.content,
                tool_calls_json: serialize_tool_calls(msg),
                model_id: (msg.model_id if msg.respond_to?(:model_id))
              )
            end
          end
        end

        # @param thread_id [String]
        def clear(thread_id:)
          @model_class.where(thread_id: thread_id).delete_all
          clear_raw(thread_id: thread_id)
          clear_compactions(thread_id: thread_id)
        end

        # -----------------------------------------------------------------------
        # Raw message interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param messages     [Array]
        # @param starting_seq [Integer]
        def append_raw(thread_id:, messages:, starting_seq:)
          return unless @raw_model_class

          messages.each_with_index do |msg, i|
            @raw_model_class.create!(
              thread_id: thread_id,
              seq: starting_seq + i,
              role: msg.role.to_s,
              content: msg.content,
              tool_calls_json: serialize_tool_calls(msg),
              model_id: (msg.model_id if msg.respond_to?(:model_id))
            )
          end
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_raw(thread_id:)
          return [] unless @raw_model_class

          records = @raw_model_class.where(thread_id: thread_id).order(:seq).to_a
          records.map { |r| {seq: r.seq, message: to_message_struct(r)} }
        end

        # @param thread_id [String]
        def clear_raw(thread_id:)
          @raw_model_class&.where(thread_id: thread_id)&.delete_all
        end

        # -----------------------------------------------------------------------
        # Compaction record interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param start_seq    [Integer]
        # @param end_seq      [Integer]
        # @param summary_text [String]
        def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
          ensure_compaction_model!
          @compaction_model_class.create!(
            thread_id: thread_id,
            start_seq: start_seq,
            end_seq: end_seq,
            summary_text: summary_text
          )
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_compactions(thread_id:)
          return [] unless @compaction_model_class

          records = @compaction_model_class.where(thread_id: thread_id).order(:start_seq).to_a
          records.map { |r| {start_seq: r.start_seq, end_seq: r.end_seq, summary_text: r.summary_text} }
        end

        # @param thread_id [String]
        def clear_compactions(thread_id:)
          @compaction_model_class&.where(thread_id: thread_id)&.delete_all
        end

        # Remove messages for a thread that were created before +older_than+.
        # Only the legacy message store is filtered; raw and compaction records
        # are left untouched because they use seq-based addressing.
        #
        # @param thread_id  [String]
        # @param older_than [Time]
        def purge_older_than(thread_id:, older_than:)
          @model_class.where(thread_id: thread_id).where("created_at < ?", older_than).delete_all
        end

        private

        def ensure_raw_model!
          raise NotImplementedError, "raw_model_class is required for raw message storage" unless @raw_model_class
        end

        def ensure_compaction_model!
          raise NotImplementedError, "compaction_model_class is required for compaction record storage" unless @compaction_model_class
        end

        def serialize_tool_calls(msg)
          return unless msg.respond_to?(:tool_calls) && msg.tool_calls

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
          MessageStruct.new(
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
end
