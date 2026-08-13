# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # LLM adapter that delegates to the RubyLLM blocking client.
    #
    # This is the default adapter used by Phronomy agents. It wraps
    # +chat.ask+ (and its streaming variant) so that the synchronous provider
    # call runs inside {OffloadPool} rather than on the EventLoop thread.
    #
    # @example Explicitly configuring this adapter
    #   Phronomy.configure do |c|
    #     c.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
    #   end
    class RubyLLM < Base
      # Delegates to +chat.ask(message)+ or +chat.complete+ when message is nil.
      #
      # Passing +nil+ for +message+ is used by the ReAct loop for continuation
      # turns where the user message has already been added to the chat history
      # (e.g. after a tool result) and the LLM should continue without a new
      # user turn.
      #
      # @param chat    [Object]      RubyLLM chat session
      # @param message [String, nil] user message, or nil to continue the chat
      # @param config  [Hash]        invocation config (not used directly by this impl)
      # @return [Object] RubyLLM response
      # @api private
      def complete(chat, message, config: {})
        message ? chat.ask(message) : chat.complete
      end

      # Delegates to +chat.ask(message) { |chunk| block.call(chunk) }+ or
      # +chat.complete(&block)+ when message is nil.
      #
      # @param chat    [Object]      RubyLLM chat session
      # @param message [String, nil] user message, or nil to continue the chat
      # @param config  [Hash]        invocation config
      # @yield [chunk] streaming chunk forwarded from +chat.ask+ / +chat.complete+
      # @return [Object] RubyLLM response
      # @api private
      def stream(chat, message, config: {}, &block)
        message ? chat.ask(message, &block) : chat.complete(&block)
      end
    end
  end
end
