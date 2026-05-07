# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Memory
    module Pruner
      # Truncates oversized tool-call result messages (role: :tool).
      #
      # Large tool outputs — such as a full web-page dump or a massive JSON
      # response — can consume a significant fraction of the context window.
      # This pruner truncates the content of any :tool message whose character
      # count exceeds max_chars, appending a note that the output was truncated.
      #
      # @example
      #   pruner = Phronomy::Memory::Pruner::ToolOutputPruner.new(max_chars: 4000)
      #   messages = pruner.prune(messages)
      class ToolOutputPruner < Base
        TRUNCATION_NOTE = "\n[... output truncated ...]"

        # @param max_chars [Integer] maximum character length for tool-result content
        def initialize(max_chars: 4000)
          @max_chars = max_chars
        end

        # @param messages [Array] message-like objects
        # @return [Array] messages with oversized :tool results truncated
        def prune(messages)
          messages.map do |msg|
            next msg unless tool_message?(msg)
            next msg if msg.content.to_s.length <= @max_chars

            truncated = msg.content.to_s[0, @max_chars] + TRUNCATION_NOTE
            clone_message(msg, truncated)
          end
        end

        private

        def tool_message?(msg)
          msg.role.to_sym == :tool
        end

        def clone_message(original, new_content)
          attrs = { role: original.role, content: new_content }
          attrs[:tool_calls] = original.tool_calls if original.respond_to?(:tool_calls)
          attrs[:model_id]   = original.model_id   if original.respond_to?(:model_id)
          OpenStruct.new(attrs)
        end
      end
    end
  end
end
