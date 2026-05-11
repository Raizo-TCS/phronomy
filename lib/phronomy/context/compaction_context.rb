# frozen_string_literal: true

module Phronomy
  module Context
    # Context object passed to the +on_compact+ callback registered on an agent.
    #
    # The callback calls #compact one or more times to specify which ranges of
    # messages to replace with a summary. Each call:
    #   1. Yields the selected message elements to the block.
    #   2. Receives the block's return value as the summary text.
    #   3. Persists a compaction record to the memory store (if available).
    #   4. Updates #result_messages so that the compacted range is replaced
    #      by a single +:system+ summary message.
    #
    # The agent reads #result_messages after the callback returns and uses it
    # as the new message list for this invocation.
    #
    # @example Summarise the oldest half of the conversation
    #   on_compact do |ctx|
    #     half = ctx.message_elements.length / 2
    #     ctx.compact(0...half) do |elements|
    #       texts = elements.map { |e| "#{e[:role]}: #{e[:message].content}" }.join("\n")
    #       "Summary of earlier conversation:\n#{texts}"
    #     end
    #   end
    class CompactionContext
      # Internal value object for synthetic summary messages.
      # Uses Struct (not OpenStruct) so that unknown attribute access raises NoMethodError.
      SummaryMessage = Struct.new(:role, :content, keyword_init: true)
      private_constant :SummaryMessage

      # @return [Array<Hash>] message elements at compaction time
      attr_reader :message_elements

      # @return [Phronomy::Context::TokenBudget, nil]
      attr_reader :budget

      # @return [Integer] total estimated token count before compaction
      attr_reader :total_tokens

      # The current message list to be used after all compact calls have been made.
      # Updated by each call to #compact.
      #
      # @return [Array]
      attr_reader :result_messages

      # @param message_elements [Array<Hash>]
      #   each element: { seq: Integer, message: Object, tokens: Integer, role: Symbol }
      # @param budget [Phronomy::Context::TokenBudget, nil]
      # @param thread_id [String, nil] used when saving compaction records
      # @param memory [Object, nil] memory object; must respond to #save_compaction
      #   for compaction records to be persisted
      def initialize(message_elements:, budget:, thread_id: nil, memory: nil)
        @message_elements = message_elements.dup
        @budget = budget
        @total_tokens = message_elements.sum { |e| e[:tokens] }
        @thread_id = thread_id
        @memory = memory
        @result_messages = @message_elements.map { |e| e[:message] }
      end

      # Replace a range of messages with a summary produced by the block.
      #
      # The block receives the selected Array<Hash> elements and must return a
      # String that serves as the summary text. After the call, #result_messages
      # reflects the replacement.
      #
      # If the memory object responds to #save_compaction, a compaction record
      # { start_seq:, end_seq:, summary_text: } is persisted for auditability.
      #
      # @param range [Range, Integer] index range into message_elements (0-based)
      # @yieldparam elements [Array<Hash>] the selected message elements
      # @yieldreturn [String] summary text to replace the selected messages
      # @return [Array] the updated result_messages array
      def compact(range)
        # Normalise: Integer index → single-element Array; Range → Array slice.
        raw = @message_elements[range]
        elements = if raw.is_a?(Array)
          raw
        elsif raw.nil?
          []
        else
          [raw]
        end
        return @result_messages if elements.empty?

        summary_text = yield(elements).to_s

        start_seq = elements.first[:seq]
        end_seq = elements.last[:seq]

        if @memory && @thread_id && @memory.respond_to?(:save_compaction)
          @memory.save_compaction(
            thread_id: @thread_id,
            start_seq: start_seq,
            end_seq: end_seq,
            summary_text: summary_text
          )
        end

        # Compute the last included index in the original @message_elements array.
        last_idx = if range.is_a?(Range)
          range.exclude_end? ? range.last - 1 : range.last
        else
          range.to_i
        end

        remaining = (@message_elements[(last_idx + 1)..] || []).map { |e| e[:message] }
        summary_msg = SummaryMessage.new(role: :system, content: summary_text)
        @result_messages = [summary_msg] + remaining
      end
    end
  end
end
