# frozen_string_literal: true

module Phronomy
  module Memory
    module Storage
      # Abstract base class for conversation storage backends.
      #
      # Each backend manages two independent datasets per thread:
      #
      #   1. Raw messages  — the original, unmodified conversation history.
      #      Every message is stored with a monotonically increasing seq number
      #      (0-based, scoped to thread_id). Raw messages are never modified or
      #      deleted; they are the authoritative record.
      #
      #   2. Compaction records — the output of LLM-based compaction (summarization).
      #      Each record covers a contiguous range [start_seq..end_seq] of raw
      #      messages and stores the summary text produced for that range.
      #      Multiple non-overlapping compaction records may exist per thread.
      #
      # The conventional load/save/clear interface is kept for backward
      # compatibility and is used by legacy Memory::* classes.
      #
      # @abstract Subclass and implement all abstract methods.
      class Base
        # -----------------------------------------------------------------------
        # Legacy interface (used by Memory::WindowMemory, EntityMemory, etc.)
        # -----------------------------------------------------------------------

        # Load all messages for a thread in chronological order.
        #
        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          raise NotImplementedError, "#{self.class}#load is not implemented"
        end

        # Persist messages for a thread (replaces existing messages).
        #
        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          raise NotImplementedError, "#{self.class}#save is not implemented"
        end

        # Delete all messages for a thread.
        #
        # @param thread_id [String]
        def clear(thread_id:)
          raise NotImplementedError, "#{self.class}#clear is not implemented"
        end

        # -----------------------------------------------------------------------
        # Raw message interface
        # -----------------------------------------------------------------------

        # Append new messages to the raw history for a thread.
        # Each message is stored together with its seq number.
        #
        # @param thread_id    [String]
        # @param messages     [Array]  message objects to append
        # @param starting_seq [Integer] seq number to assign to messages[0]
        def append_raw(thread_id:, messages:, starting_seq:)
          raise NotImplementedError, "#{self.class}#append_raw is not implemented"
        end

        # Return all raw messages for a thread as an array of hashes.
        #
        # @param thread_id [String]
        # @return [Array<Hash>] each entry: { seq: Integer, message: Object }
        def load_raw(thread_id:)
          raise NotImplementedError, "#{self.class}#load_raw is not implemented"
        end

        # Delete raw messages for a thread (used in #clear).
        #
        # @param thread_id [String]
        def clear_raw(thread_id:)
          raise NotImplementedError, "#{self.class}#clear_raw is not implemented"
        end

        # -----------------------------------------------------------------------
        # Compaction record interface
        # -----------------------------------------------------------------------

        # Persist a compaction record for a thread.
        # A compaction record stores the LLM-generated summary that covers raw
        # messages from start_seq to end_seq (inclusive).
        #
        # @param thread_id    [String]
        # @param start_seq    [Integer]
        # @param end_seq      [Integer]
        # @param summary_text [String]
        def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
          raise NotImplementedError, "#{self.class}#save_compaction is not implemented"
        end

        # Return all compaction records for a thread in ascending start_seq order.
        #
        # @param thread_id [String]
        # @return [Array<Hash>] each entry: { start_seq:, end_seq:, summary_text: }
        def load_compactions(thread_id:)
          raise NotImplementedError, "#{self.class}#load_compactions is not implemented"
        end

        # Delete all compaction records for a thread.
        #
        # @param thread_id [String]
        def clear_compactions(thread_id:)
          raise NotImplementedError, "#{self.class}#clear_compactions is not implemented"
        end
      end
    end
  end
end
