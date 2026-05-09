# frozen_string_literal: true

module Phronomy
  module Memory
    # ConversationManager combines the three independent axes of conversation handling:
    #   - Storage:     where messages are persisted (InMemory, ActiveRecord, ...)
    #   - Retrieval:   which messages to select (Recent, Semantic, ...)
    #   - Compression: how to reduce message size before storage (Summary, ToolOutputPruner, ...)
    #
    # This is the primary entry point for context region 4 (Conversation) in Agent::Base.
    #
    # === Original preservation policy
    #
    # All original messages are appended to Storage's raw history with a
    # monotonically increasing seq number (0-based, per thread). Raw messages
    # are never modified or deleted.
    #
    # When Compression::Summary performs a compaction, a compaction record
    # { start_seq:, end_seq:, summary_text: } is saved in Storage alongside the
    # raw messages. This allows callers to reconstruct the full history or audit
    # which messages were summarised.
    #
    # On #load, the message list is reconstructed from raw history + compaction
    # records: each compacted range is replaced by a single summary system message,
    # and uncompacted messages are returned verbatim.
    #
    # @example Simple recency-based in-memory manager
    #   manager = Phronomy::Memory::ConversationManager.new(
    #     storage:   Phronomy::Memory::Storage::InMemory.new,
    #     retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 10)
    #   )
    #
    # @example With LLM summary compaction
    #   manager = Phronomy::Memory::ConversationManager.new(
    #     storage:     Phronomy::Memory::Storage::InMemory.new,
    #     retrieval:   Phronomy::Memory::Retrieval::Recent.new(k: 5),
    #     compression: Phronomy::Memory::Compression::Summary.new(max_tokens: 4000)
    #   )
    class ConversationManager
      # @param storage     [Memory::Storage::Base]     persistence backend (required)
      # @param retrieval   [Memory::Retrieval::Base]   selection strategy (required)
      # @param compression [Memory::Compression::Base, nil] optional compression strategy
      def initialize(storage:, retrieval:, compression: nil)
        @storage = storage
        @retrieval = retrieval
        @compression = compression
      end

      # Load conversation messages for a thread, applying retrieval selection.
      #
      # Reconstructs the message list from raw history + compaction records:
      #   - Each compacted range [start_seq..end_seq] is replaced by a summary
      #     system message.
      #   - Uncompacted messages are returned in original order.
      #
      # @param thread_id [String]
      # @param query     [String, nil] current user input for query-aware retrieval
      # @return [Array]
      def load(thread_id:, query: nil)
        messages = reconstruct(thread_id)
        @retrieval.select(messages, query: query)
      end

      # Persist new messages for a thread and optionally apply compression.
      #
      # New messages are determined by comparing the incoming array length with
      # the existing raw history length (messages are always append-only).
      # Only truly new messages (beyond raw.length) are appended to raw storage.
      #
      # When a compression strategy is configured, it is evaluated against the
      # full set of uncompacted raw messages. If compaction fires, the resulting
      # compaction record is saved in storage (originals are preserved).
      #
      # @param thread_id [String]
      # @param messages  [Array] full conversation history up to this point
      def save(thread_id:, messages:)
        append_new_messages(thread_id: thread_id, messages: messages)
        compress_and_save(thread_id: thread_id, messages: messages)
        @retrieval.index(thread_id: thread_id, messages: messages) if @retrieval.respond_to?(:index)
      end

      # Delete all messages (raw, compaction records, and legacy store) for a thread.
      #
      # @param thread_id [String]
      def clear(thread_id:)
        @storage.clear(thread_id: thread_id)
        @retrieval.clear_index(thread_id: thread_id) if @retrieval.respond_to?(:clear_index)
      end

      # Record an application-driven compaction for a thread.
      # Called by CompactionContext when the on_compact callback invokes ctx.compact.
      #
      # @param thread_id   [String]
      # @param start_seq   [Integer] first seq number in the compacted range
      # @param end_seq     [Integer] last seq number in the compacted range
      # @param summary_text [String] replacement text for the compacted messages
      def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
        @storage.save_compaction(
          thread_id: thread_id,
          start_seq: start_seq,
          end_seq: end_seq,
          summary_text: summary_text
        )
      end

      private

      # Append messages that are new since the last save to the raw history.
      # Messages are append-only; existing raw entries are never modified.
      def append_new_messages(thread_id:, messages:)
        raw = @storage.load_raw(thread_id: thread_id)
        starting_seq = raw.length
        new_messages = messages[starting_seq..]
        @storage.append_raw(thread_id: thread_id, messages: new_messages, starting_seq: starting_seq) if new_messages&.any?
      end

      # Apply the configured compression strategy and persist the result.
      # When no strategy is configured, saves messages directly to the legacy store.
      # When compression fires, also persists the compaction record.
      def compress_and_save(thread_id:, messages:)
        unless @compression
          @storage.save(thread_id: thread_id, messages: messages)
          return
        end

        compactions = @storage.load_compactions(thread_id: thread_id)
        uncompacted_start_seq = compactions.any? ? compactions.last[:end_seq] + 1 : 0
        all_raw = @storage.load_raw(thread_id: thread_id)
        uncompacted = all_raw.select { |r| r[:seq] >= uncompacted_start_seq }.map { |r| r[:message] }

        result = @compression.compress(
          thread_id: thread_id,
          messages: uncompacted,
          seq_offset: uncompacted_start_seq
        )

        if result[:compaction]
          @storage.save_compaction(
            thread_id: thread_id,
            start_seq: result[:compaction][:start_seq],
            end_seq: result[:compaction][:end_seq],
            summary_text: result[:compaction][:summary_text]
          )
        end

        # For non-Summary compressors (ToolOutputPruner), store the pruned
        # version in the legacy store so legacy #load still works.
        @storage.save(thread_id: thread_id, messages: result[:messages])
      end

      # Reconstruct context-ready messages from raw history + compaction records.
      # When no compaction records exist (no Summary compaction has fired), we
      # return the legacy store directly — this preserves the effect of content
      # pruners like ToolOutputPruner, whose pruned messages are saved there.
      # When compaction records exist, we rebuild the context from raw history:
      # each compacted seq range is replaced by a single summary system message.
      def reconstruct(thread_id)
        compactions = @storage.load_compactions(thread_id: thread_id)
        return @storage.load(thread_id: thread_id) if compactions.empty?

        raw = @storage.load_raw(thread_id: thread_id)
        last_compacted_seq = compactions.last[:end_seq]
        summary_msgs = compactions.map { |c| summary_message(c[:summary_text]) }
        uncompacted = raw.select { |r| r[:seq] > last_compacted_seq }.map { |r| r[:message] }
        summary_msgs + uncompacted
      end

      def summary_message(text)
        require "ostruct"
        content = <<~CONTEXT.chomp
          <context type="summary" source="memory" trusted="false">
          #{text}
          </context>
        CONTEXT
        OpenStruct.new(role: :system, content: content)
      end
    end
  end
end
