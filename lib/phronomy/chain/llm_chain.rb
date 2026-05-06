# frozen_string_literal: true

module Phronomy
  module Chain
    # LLM invocation component wrapping RubyLLM.
    # invoke accepts a String or { system:, user: } Hash and returns a String.
    class LLMChain
      include Phronomy::Runnable

      # @param model [String, nil] model name (nil delegates to RubyLLM default)
      # @param tools [Array] tools available to the chat
      # @param temperature [Float, nil] sampling temperature
      def initialize(model: nil, tools: [], temperature: nil)
        @model = model
        @tools = tools
        @temperature = temperature
      end

      # @param input [String, Hash] String or { system:, user: } Hash
      # @return [String] LLM response text
      def invoke(input, config: {})
        chat = build_chat(config)

        response = case input
        when String
          chat.ask(input)
        when Hash
          chat.with_instructions(input[:system]) if input[:system]
          chat.ask(input[:user] || input[:message])
        end

        response.content
      end

      # @param input [String, Hash] same format as invoke
      # @yield [String] streaming chunk
      def stream(input, config: {}, &block)
        chat = build_chat(config)

        response = case input
        when String
          chat.ask(input, &block)
        when Hash
          chat.with_instructions(input[:system]) if input[:system]
          chat.ask(input[:user] || input[:message], &block)
        end

        response.content
      end

      private

      def build_chat(config)
        opts = {}
        opts[:model] = @model || config[:model] if @model || config[:model]
        opts[:temperature] = @temperature if @temperature
        chat = RubyLLM.chat(**opts)
        @tools.each { |t| chat.with_tool(t) }
        chat
      end
    end
  end
end
