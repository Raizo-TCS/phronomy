# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Memory
    # Memory that compresses context by summarizing old messages with an LLM.
    # When the token threshold is exceeded, all messages except the most recent 5
    # are summarized and replaced with a single system message.
    #
    # When a token_budget is passed to load_messages, budget.effective_input_limit
    # is used as the threshold. Otherwise the constructor's max_tokens is used.
    class SummaryMemory < Base
      def initialize(max_tokens: 4000, summarizer_model: nil, summarizer_provider: nil, async: false, queue: :default)
        super(async: async, queue: queue)
        @max_tokens = max_tokens
        @summarizer_model = summarizer_model
        @summarizer_provider = summarizer_provider
        @store = {}
        @summaries = {}
      end

      # @param thread_id    [String]
      # @param token_budget [Phronomy::Context::TokenBudget, nil]
      # @return [Array]
      def load_messages(thread_id:, token_budget: nil, query: nil, **)
        summary = @summaries[thread_id]
        recent = @store[thread_id] || []

        if summary
          [summary_message(summary)] + recent
        else
          recent
        end
      end

      def save_messages(thread_id:, messages:, token_budget: nil)
        threshold = token_budget ? token_budget.effective_input_limit : @max_tokens
        estimated_tokens = messages.sum { |m| Phronomy::Context::TokenEstimator.estimate(m.content.to_s) }

        if estimated_tokens > threshold
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
        # Wrap in a structural marker to distinguish the summarized conversation
        # history (external data) from authoritative system instructions.
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
