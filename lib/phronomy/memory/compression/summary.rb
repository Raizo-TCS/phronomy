# frozen_string_literal: true

module Phronomy
  module Memory
    module Compression
      # Compaction strategy that summarizes old messages with an LLM.
      #
      # When the total estimated token count of the uncompacted message history
      # exceeds +max_tokens+, all messages except the most recent +keep+ are
      # summarized by an LLM. The original messages are preserved in Storage
      # (via ConversationManager); this class only decides whether compaction is
      # needed and produces the summary text.
      #
      # The #compress method now returns a Hash instead of a plain Array:
      #   {
      #     messages:   Array,            # context-ready message list
      #     compaction: Hash | nil        # { start_seq:, end_seq:, summary_text: }
      #                                   # nil when no compaction was performed
      #   }
      #
      # ConversationManager uses the :compaction entry to persist the compaction
      # record in Storage, ensuring originals are never discarded.
      #
      # @example
      #   compressor = Phronomy::Memory::Compression::Summary.new(
      #     max_tokens: 4000,
      #     summarizer_model: "gpt-4o-mini"
      #   )
      #   manager = Phronomy::Memory::ConversationManager.new(
      #     storage: storage,
      #     retrieval: retrieval,
      #     compression: compressor
      #   )
      class Summary < Base
        # @param max_tokens          [Integer]     token threshold above which old messages are compacted
        # @param keep                [Integer]     number of recent messages to preserve verbatim
        # @param summarizer_model    [String, nil] LLM model for summarization; nil uses global default
        # @param summarizer_provider [Symbol, nil] LLM provider; required for unregistered models
        def initialize(max_tokens: 4000, keep: 5, summarizer_model: nil, summarizer_provider: nil)
          @max_tokens = max_tokens
          @keep = keep
          @summarizer_model = summarizer_model
          @summarizer_provider = summarizer_provider
        end

        # Evaluate whether compaction is needed and produce a summary if so.
        #
        # +seq_offset+ is the seq number of messages[0] in the raw history.
        # ConversationManager passes this so the compaction record can reference
        # the correct seq range in Storage.
        #
        # @param thread_id  [String]
        # @param messages   [Array]   uncompacted messages to consider
        # @param seq_offset [Integer] seq number assigned to messages[0]
        # @return [Hash] { messages: Array, compaction: Hash|nil }
        #   compaction is { start_seq:, end_seq:, summary_text: } or nil
        def compress(thread_id:, messages:, seq_offset: 0)
          estimated = messages.sum { |m| Phronomy::Context::TokenEstimator.estimate(m.content.to_s) }

          if estimated > @max_tokens && messages.length > @keep
            compact(messages, seq_offset: seq_offset)
          else
            {messages: messages, compaction: nil}
          end
        rescue => e
          warn "[Phronomy] Compression failed (#{e.class}: #{e.message}); saving without compaction."
          {messages: messages, compaction: nil}
        end

        private

        def compact(messages, seq_offset:)
          old_count = messages.length - @keep
          old_messages = messages[0, old_count]
          recent_messages = messages[old_count..]

          opts = {}
          opts[:model] = @summarizer_model if @summarizer_model
          opts[:provider] = @summarizer_provider if @summarizer_provider
          opts[:assume_model_exists] = true if @summarizer_provider
          chat = RubyLLM.chat(**opts)
          summary_text = chat.ask(
            "Please summarize the following conversation concisely:\n" +
              old_messages.map { |m| "#{m.role}: #{m.content}" }.join("\n")
          ).content

          compaction_record = {
            start_seq: seq_offset,
            end_seq: seq_offset + old_count - 1,
            summary_text: summary_text
          }

          {messages: [summary_message(summary_text)] + recent_messages, compaction: compaction_record}
        end

        def summary_message(text)
          content = <<~CONTEXT.chomp
            <context type="summary" source="memory" trusted="false">
            #{text}
            </context>
          CONTEXT
          RubyLLM::Message.new(role: :system, content: content)
        end
      end
    end
  end
end
