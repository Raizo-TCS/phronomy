# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Memory
    # Memory that compresses context by summarizing old messages with an LLM.
    # When the token threshold is exceeded, all messages except the most recent 5
    # are summarized and replaced with a single system message.
    #
    # === Original preservation policy
    #
    # All original messages are stored in +@raw_store+ and never modified.
    # When compaction fires, a compaction record { start_seq:, end_seq:,
    # summary_text: } is appended to +@compaction_records+. This allows callers
    # to retrieve the full unmodified history via #load_raw_messages and
    # #compaction_records.
    class SummaryMemory < Base
      # @param max_tokens          [Integer]        token threshold above which old messages are summarized
      # @param summarizer_model    [String, nil]    LLM model used for summarization; nil uses the global default
      # @param summarizer_provider [Symbol, nil]    LLM provider for the summarizer; required for unregistered models
      # @param async               [Boolean]        see {Phronomy::Memory::Base#initialize}
      # @param queue               [Symbol, String] see {Phronomy::Memory::Base#initialize}
      def initialize(max_tokens: 4000, summarizer_model: nil, summarizer_provider: nil, async: false, queue: :default)
        super(async: async, queue: queue)
        @max_tokens = max_tokens
        @summarizer_model = summarizer_model
        @summarizer_provider = summarizer_provider
        @store = {}
        @summaries = {}
        @raw_store = {}          # thread_id => [{seq:, message:}, ...]
        @compaction_records = {} # thread_id => [{start_seq:, end_seq:, summary_text:}, ...]
      end

      # @param thread_id [String]
      # @return [Array]
      def load_messages(thread_id:, query: nil, **)
        summary = @summaries[thread_id]
        recent = @store[thread_id] || []

        if summary
          [summary_message(summary)] + recent
        else
          recent
        end
      end

      # Returns the raw (original, unmodified) message history for a thread.
      # Each entry is a Hash: { seq: Integer, message: Object }.
      #
      # @param thread_id [String]
      # @return [Array<Hash>]
      def load_raw_messages(thread_id:)
        (@raw_store[thread_id] || []).dup
      end

      # Returns all compaction records for a thread.
      # Each entry is a Hash: { start_seq:, end_seq:, summary_text: }.
      #
      # @param thread_id [String]
      # @return [Array<Hash>]
      def compaction_records(thread_id:)
        (@compaction_records[thread_id] || []).dup
      end

      # Saves messages, compressing via LLM summarization when the estimated token
      # count exceeds max_tokens. Originals are always preserved in @raw_store.
      #
      # @param thread_id [String]
      # @param messages  [Array]
      def save_messages(thread_id:, messages:, **)
        # Append only new messages to the raw history.
        raw = @raw_store[thread_id] || []
        starting_seq = raw.length
        new_messages = messages[starting_seq..]
        if new_messages&.any?
          @raw_store[thread_id] ||= []
          new_messages.each_with_index do |msg, i|
            @raw_store[thread_id] << {seq: starting_seq + i, message: msg}
          end
        end

        estimated_tokens = messages.sum { |m| Phronomy::Context::TokenEstimator.estimate(m.content.to_s) }

        if estimated_tokens > @max_tokens
          compress(thread_id, messages)
        else
          @store[thread_id] = messages
        end
      end

      # @param thread_id [String]
      def clear(thread_id:)
        @store.delete(thread_id)
        @summaries.delete(thread_id)
        @raw_store.delete(thread_id)
        @compaction_records.delete(thread_id)
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

        # Determine seq range from raw store.
        existing_compactions = @compaction_records[thread_id] || []
        start_seq = existing_compactions.any? ? existing_compactions.last[:end_seq] + 1 : 0
        end_seq = start_seq + old_messages.length - 1

        @compaction_records[thread_id] ||= []
        @compaction_records[thread_id] << {start_seq: start_seq, end_seq: end_seq, summary_text: summary_text}

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
