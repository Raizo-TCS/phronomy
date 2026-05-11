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
      # @param ttl         [Integer, nil] message time-to-live in seconds; messages older
      #                    than this value are removed from storage on each {#load} call.
      #                    +nil+ disables TTL (default).
      def initialize(storage:, retrieval:, compression: nil, ttl: nil)
        @storage = storage
        @retrieval = retrieval
        @compression = compression
        @ttl = ttl
        # Per-thread mutexes allow concurrent saves for different thread_ids while
        # preventing races (duplicate compaction records) within the same thread_id.
        @thread_mutexes = {}
        @thread_mutexes_mutex = Mutex.new
        # Tracks the monotonically increasing next-seq per thread so that TTL
        # purges (which reduce raw.length) do not reset the sequence counter.
        # Protected by a dedicated mutex so concurrent saves for distinct
        # thread_ids do not race on the shared Hash (Issue #60).
        @raw_seq_hwm = {}
        @raw_seq_hwm_mutex = Mutex.new
      end

      # Load conversation messages for a thread, applying retrieval selection.
      #
      # When a TTL is configured, raw messages older than the TTL are permanently
      # removed from storage before reconstruction.
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
        @storage.purge_older_than(thread_id: thread_id, older_than: Time.now - @ttl) if @ttl
        messages = reconstruct(thread_id)
        @retrieval.select(messages, query: query, thread_id: thread_id)
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
        thread_mutex(thread_id).synchronize do
          append_new_messages_unlocked(thread_id: thread_id, messages: messages)
          compress_and_save(thread_id: thread_id, messages: messages)
        end
        @retrieval.index(thread_id: thread_id, messages: messages) if @retrieval.respond_to?(:index)
      end

      # Delete all messages (raw, compaction records, and legacy store) for a thread.
      #
      # @param thread_id [String]
      def clear(thread_id:)
        @storage.clear(thread_id: thread_id)
        @retrieval.clear_index(thread_id: thread_id) if @retrieval.respond_to?(:clear_index)
      end

      # Permanently erase all stored data for a thread (right-to-erasure / purge).
      # Delegates to the storage backend's {Storage::Base#purge} and also clears
      # any retrieval index for the thread.
      #
      # @param thread_id [String]
      def purge(thread_id:)
        @storage.purge(thread_id: thread_id)
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

      # Returns (or lazily creates) the per-thread mutex for +thread_id+.
      # The outer @thread_mutexes_mutex protects the hash from concurrent creation.
      def thread_mutex(thread_id)
        @thread_mutexes_mutex.synchronize do
          @thread_mutexes[thread_id] ||= Mutex.new
        end
      end

      # Append messages that are new since the last save to the raw history.
      # Must be called while holding the per-thread mutex (via thread_mutex).
      # Messages are append-only; existing raw entries are never modified.
      #
      # Uses a per-thread high-water-mark (HWM) to determine the next seq number.
      # The HWM is the maximum of:
      #   - The highest seq stored in the raw store (correct after normal appends)
      #   - The in-memory HWM (correct after TTL purge empties the raw store)
      # This prevents seq number collisions when TTL purge reduces raw.length.
      def append_new_messages_unlocked(thread_id:, messages:)
        raw = @storage.load_raw(thread_id: thread_id)
        # Derive the next seq from the raw store's high-water-mark seq when
        # entries are present. Fall back to the in-memory HWM when the raw
        # store has been partially or fully purged by TTL expiry.
        stored_next_seq = raw.any? ? raw.map { |e| e[:seq] }.max + 1 : nil
        hwm = @raw_seq_hwm_mutex.synchronize { @raw_seq_hwm[thread_id] }
        next_seq = [stored_next_seq, hwm].compact.max || 0
        new_messages = messages[next_seq..]
        if new_messages&.any?
          @storage.append_raw(thread_id: thread_id, messages: new_messages, starting_seq: next_seq)
          @raw_seq_hwm_mutex.synchronize { @raw_seq_hwm[thread_id] = next_seq + new_messages.length }
        end
      end

      # Apply the configured compression strategy and persist the result.
      # When no strategy is configured, saves messages directly to the legacy store.
      # When compression fires, also persists the compaction record.
      # If the compression strategy raises (e.g. LLM timeout), we fall back to
      # saving the messages without compaction so the conversation is never lost
      # due to a transient summarization failure (Issue #58).
      def compress_and_save(thread_id:, messages:)
        unless @compression
          @storage.save(thread_id: thread_id, messages: messages)
          return
        end

        compactions = @storage.load_compactions(thread_id: thread_id)
        uncompacted_start_seq = compactions.any? ? compactions.last[:end_seq] + 1 : 0
        all_raw = @storage.load_raw(thread_id: thread_id)
        uncompacted = all_raw.select { |r| r[:seq] >= uncompacted_start_seq }.map { |r| r[:message] }

        result = begin
          @compression.compress(
            thread_id: thread_id,
            messages: uncompacted,
            seq_offset: uncompacted_start_seq
          )
        rescue => e
          warn "[Phronomy] Compression failed (#{e.class}: #{e.message}); saving without compaction."
          {messages: messages, compaction: nil}
        end

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

      # Immutable value object used as a summary placeholder in reconstructed context.
      SummaryMessage = Data.define(:role, :content)

      def summary_message(text)
        content = <<~CONTEXT.chomp
          <context type="summary" source="memory" trusted="false">
          #{text}
          </context>
        CONTEXT
        SummaryMessage.new(role: :system, content: content)
      end
    end
  end
end
