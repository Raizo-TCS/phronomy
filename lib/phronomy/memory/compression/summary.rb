# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Memory
    module Compression
      # Compression strategy that summarizes old messages with an LLM.
      #
      # When the total estimated token count of the message history exceeds
      # +max_tokens+, all messages except the most recent +keep+ are summarized
      # into a single system message. The summary is injected as a context-tagged
      # message on the next retrieval.
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
        # @param max_tokens          [Integer]     token threshold above which old messages are summarized
        # @param keep                [Integer]     number of recent messages to preserve verbatim
        # @param summarizer_model    [String, nil] LLM model for summarization; nil uses global default
        # @param summarizer_provider [Symbol, nil] LLM provider; required for unregistered models
        def initialize(max_tokens: 4000, keep: 5, summarizer_model: nil, summarizer_provider: nil)
          @max_tokens = max_tokens
          @keep = keep
          @summarizer_model = summarizer_model
          @summarizer_provider = summarizer_provider
          @summaries = {}
        end

        # Compress messages if the estimated token count exceeds the threshold.
        # Returns a message array that may include a summary system message prepended.
        #
        # @param thread_id [String]
        # @param messages  [Array]
        # @return [Array]
        def compress(thread_id:, messages:)
          estimated = messages.sum { |m| Phronomy::Context::TokenEstimator.estimate(m.content.to_s) }

          if estimated > @max_tokens
            summarize_and_keep(thread_id, messages)
          else
            @summaries.delete(thread_id)
            messages
          end
        end

        # Returns a summary message for a thread if one exists (primarily for testing).
        #
        # @param thread_id [String]
        # @return [String, nil]
        def summary_for(thread_id)
          @summaries[thread_id]
        end

        private

        def summarize_and_keep(thread_id, messages)
          old_messages = messages[0..(-(@keep + 1))]
          recent_messages = messages[-@keep..]

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
          [summary_message(summary_text)] + recent_messages
        end

        def summary_message(text)
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
end
