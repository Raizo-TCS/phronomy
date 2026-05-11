# frozen_string_literal: true

module Phronomy
  module Memory
    module Compression
      # Compression strategy that truncates oversized tool-call result messages.
      #
      # Large tool outputs — such as a full web-page dump or a massive JSON
      # response — can consume a significant fraction of the context window.
      # This compressor truncates the content of any :tool message whose character
      # count exceeds max_chars, appending a note that the output was truncated.
      #
      # Unlike Summary, this is a stateless compressor: it does not accumulate
      # state across calls and requires no thread_id bookkeeping.
      #
      # @example
      #   compressor = Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 4000)
      #   manager = Phronomy::Memory::ConversationManager.new(
      #     storage: storage,
      #     retrieval: retrieval,
      #     compression: compressor
      #   )
      class ToolOutputPruner < Base
        TRUNCATION_NOTE = "\n[... output truncated ...]"

        # Internal value object for cloned messages.
        # Uses Struct (not OpenStruct) so that unknown attribute access raises NoMethodError.
        ClonedMessage = Struct.new(:role, :content, :tool_calls, :model_id, keyword_init: true)
        private_constant :ClonedMessage

        # @param max_chars [Integer] maximum character length for tool-result content
        def initialize(max_chars: 4000)
          @max_chars = max_chars
        end

        # Truncate oversized :tool messages in-place (non-destructive — returns new array).
        # Content pruning does not produce a compaction record; :compaction is always nil.
        #
        # @param thread_id  [String]  unused (stateless pruner)
        # @param messages   [Array]
        # @param seq_offset [Integer] unused
        # @return [Hash] { messages: Array, compaction: nil }
        def compress(thread_id:, messages:, seq_offset: 0)
          pruned = messages.map do |msg|
            next msg unless msg.role.to_sym == :tool
            next msg if msg.content.to_s.length <= @max_chars

            truncated = msg.content.to_s[0, @max_chars] + TRUNCATION_NOTE
            clone_message(msg, truncated)
          end
          {messages: pruned, compaction: nil}
        end

        private

        def clone_message(original, new_content)
          ClonedMessage.new(
            role: original.role,
            content: new_content,
            tool_calls: (original.tool_calls if original.respond_to?(:tool_calls)),
            model_id: (original.model_id if original.respond_to?(:model_id))
          )
        end
      end
    end
  end
end
