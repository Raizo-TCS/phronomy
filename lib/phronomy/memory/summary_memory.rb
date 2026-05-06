# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Memory
    # Memory that compresses context by summarizing old messages with an LLM.
    # When max_tokens is exceeded, all messages except the most recent 5 are summarized.
    class SummaryMemory < Base
      def initialize(max_tokens: 4000, summarizer_model: nil, summarizer_provider: nil)
        @max_tokens = max_tokens
        @summarizer_model = summarizer_model
        @summarizer_provider = summarizer_provider
        @store = {}
        @summaries = {}
      end

      def load_messages(thread_id:, **)
        summary = @summaries[thread_id]
        recent = @store[thread_id] || []

        if summary
          [summary_message(summary)] + recent
        else
          recent
        end
      end

      def save_messages(thread_id:, messages:)
        estimated_tokens = messages.sum { |m| m.content.to_s.length / 4 }

        if estimated_tokens > @max_tokens
          compress(thread_id, messages)
        else
          @store[thread_id] = messages
        end
      end

      def clear(thread_id:)
        @store.delete(thread_id)
        @summaries.delete(thread_id)
      end

      private

      def compress(thread_id, messages)
        keep = 5
        old_messages = messages[0..-(keep + 1)]
        recent_messages = messages[-keep..]

        opts = {}
        opts[:model] = @summarizer_model if @summarizer_model
        opts[:provider] = @summarizer_provider if @summarizer_provider
        opts[:assume_model_exists] = true if @summarizer_provider
        chat = RubyLLM.chat(**opts)
        summary_text = chat.ask(
          "Please summarize the following conversation concisely:\n" +
            old_messages.map { |m| "#{m.role}: #{m.content}" }.join("\n")
        ).content

        @summaries[thread_id] = summary_text
        @store[thread_id] = recent_messages
      end

      def summary_message(text)
        OpenStruct.new(role: :system, content: "[Summary]\n#{text}")
      end
    end
  end
end
