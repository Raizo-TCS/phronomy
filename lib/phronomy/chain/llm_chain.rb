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
      # @param provider [Symbol, nil] explicit RubyLLM provider (e.g. :openai).
      #   When set, assume_model_exists is enabled so custom OpenAI-compatible
      #   endpoints (LM Studio, Ollama, vLLM, etc.) can be used without the
      #   provider's model registry rejecting unknown model names.
      def initialize(model: nil, tools: [], temperature: nil, provider: nil)
        @model = model
        @tools = tools
        @temperature = temperature
        @provider = provider
      end

      # @param input [String, Hash] String or { system:, user: } Hash
      # @return [String] LLM response text
      def invoke(input, config: {})
        trace("llm_chain", input: input) do
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
      end

      # @param input [String, Hash] same format as invoke
      # @yield [String] streaming chunk
      def stream(input, config: {}, &block)
        trace("llm_chain", input: input) do
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
      end

      private

      def build_chat(config)
        opts = {}
        opts[:model] = @model || config[:model] if @model || config[:model]
        opts[:temperature] = @temperature if @temperature
        if @provider
          opts[:provider] = @provider
          opts[:assume_model_exists] = true
        end
        chat = RubyLLM.chat(**opts)
        @tools.each { |t| chat.with_tool(t) }
        chat
      end
    end
  end
end
