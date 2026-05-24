# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # LLM adapter that delegates to the RubyLLM blocking client.
    #
    # This is the default adapter used by Phronomy agents.  It wraps
    # +chat.ask+ (and its streaming variant) so that the blocking HTTP
    # call runs inside {BlockingAdapterPool} rather than on the EventLoop
    # thread or the caller's thread directly.
    #
    # @example Explicitly configuring this adapter
    #   Phronomy.configure do |c|
    #     c.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
    #   end
    class RubyLLM < Base
      # Delegates to +chat.ask(message)+.
      #
      # @param chat    [Object] RubyLLM chat session
      # @param message [String] user message
      # @param config  [Hash]   invocation config (not used directly by this impl)
      # @return [Object] RubyLLM response
      # @api private
      def complete(chat, message, config: {})
        chat.ask(message)
      end

      # Delegates to +chat.ask(message) { |chunk| block.call(chunk) }+.
      #
      # @param chat    [Object] RubyLLM chat session
      # @param message [String] user message
      # @param config  [Hash]   invocation config
      # @yield [chunk] streaming chunk forwarded from +chat.ask+
      # @return [Object] RubyLLM response
      # @api private
      def stream(chat, message, config: {}, &block)
        chat.ask(message, &block)
      end
    end
  end
end
