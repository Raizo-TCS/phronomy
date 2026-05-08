# frozen_string_literal: true

module Phronomy
  module Memory
    module Compression
      # Abstract base class for compression strategies.
      #
      # Two kinds of compression exist:
      #
      # * Content pruning (e.g. ToolOutputPruner) — modifies individual message
      #   content in-place (e.g. truncates oversized tool outputs). The original
      #   data loss is limited and intentional (tool outputs are auxiliary).
      #   These subclasses return { messages: Array, compaction: nil }.
      #
      # * Compaction (e.g. Summary) — replaces multiple messages with an LLM
      #   summary. Originals are preserved in Storage via a compaction record.
      #   These subclasses return { messages: Array, compaction: Hash } where
      #   compaction is { start_seq:, end_seq:, summary_text: }.
      #
      # ConversationManager inspects the :compaction key and persists the record
      # in Storage when present.
      #
      # @abstract Subclass and implement #compress.
      class Base
        # Compress a message array and return a result hash.
        #
        # @param thread_id  [String]  thread identifier (used by stateful compressors)
        # @param messages   [Array]   message history to compress
        # @param seq_offset [Integer] seq number of messages[0] in the raw history
        # @return [Hash] { messages: Array, compaction: Hash|nil }
        def compress(thread_id:, messages:, seq_offset: 0)
          raise NotImplementedError, "#{self.class}#compress is not implemented"
        end
      end
    end
  end
end
