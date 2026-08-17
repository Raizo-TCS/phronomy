# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Default LLMAdapter SPI implementation backed by RubyLLM.
    #
    # The synchronous +chat.ask+ / +chat.complete+ calls are invoked through the
    # framework-owned async bridge in {LLMAdapter::Base}, so adapter consumers do
    # not need to manage OffloadPool themselves.
    #
    # @example Explicitly configuring this adapter
    #   Phronomy.configure do |c|
    #     c.llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
    #   end
    #
    # @api public
    class RubyLLM < Base
      # Delegates to +chat.ask(message)+ or +chat.complete+ when message is nil.
      #
      # Passing +nil+ for +message+ is used by the ReAct loop for continuation
      # turns where the user message has already been added to the chat history
      # (for example after a Tool result).
      #
      # @param chat    [Object]      RubyLLM chat session
      # @param message [String, nil] user message, or nil to continue the chat
      # @param config  [Hash]        invocation config (not used directly here)
      # @return [Object] RubyLLM response
      # @api public
      def complete(chat, message, config: {})
        message ? chat.ask(message) : chat.complete
      end

      # Delegates to +chat.ask(message) { |chunk| ... }+ or +chat.complete(&block)+
      # when message is nil.
      #
      # @param chat    [Object]      RubyLLM chat session
      # @param message [String, nil] user message, or nil to continue the chat
      # @param config  [Hash]        invocation config
      # @yield [chunk] streaming chunk forwarded from RubyLLM
      # @return [Object] RubyLLM response
      # @api public
      def stream(chat, message, config: {}, &block)
        message ? chat.ask(message, &block) : chat.complete(&block)
      end
    end
  end
end
