# frozen_string_literal: true

require "ostruct"

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

        # @param max_chars [Integer] maximum character length for tool-result content
        def initialize(max_chars: 4000)
          @max_chars = max_chars
        end

        # Truncate oversized :tool messages in-place (non-destructive — returns new array).
        #
        # @param thread_id [String] unused (stateless compressor)
        # @param messages  [Array]
        # @return [Array]
        def compress(thread_id:, messages:)
          messages.map do |msg|
            next msg unless msg.role.to_sym == :tool
            next msg if msg.content.to_s.length <= @max_chars

            truncated = msg.content.to_s[0, @max_chars] + TRUNCATION_NOTE
            clone_message(msg, truncated)
          end
        end

        private

        def clone_message(original, new_content)
          attrs = {role: original.role, content: new_content}
          attrs[:tool_calls] = original.tool_calls if original.respond_to?(:tool_calls)
          attrs[:model_id] = original.model_id if original.respond_to?(:model_id)
          OpenStruct.new(attrs)
        end
      end
    end
  end
end
