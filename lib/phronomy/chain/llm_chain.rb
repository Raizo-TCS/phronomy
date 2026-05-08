# frozen_string_literal: true

module Phronomy
  module Chain
    # A Runnable that sends a prompt to an LLM and returns the text response.
    #
    # Accepts either:
    #   - a String input  → used directly as the human message
    #   - a Hash input    → reads :prompt (required) and :system (optional) keys
    #
    # When composed after a PromptTemplate via >>, the Hash output from the
    # template flows in automatically.
    #
    # @example Standalone usage
    #   llm = Phronomy::Chain::LLMChain.new(model: "gpt-4o-mini")
    #   result = llm.invoke("What is the capital of Japan?")
    #   result[:output] # => "Tokyo"
    #
    # @example Composed with a PromptTemplate
    #   chain = Phronomy::Chain::PromptTemplate.new(template: "Say hello in {{lang}}.") >>
    #           Phronomy::Chain::LLMChain.new(model: "gpt-4o-mini")
    #   result = chain.invoke(lang: "Spanish")
    #   result[:output] # => "Hola!"
    class LLMChain
      include Phronomy::Runnable

      # @param model       [String]  RubyLLM model identifier
      # @param provider    [Symbol, nil]  explicit provider (optional)
      # @param temperature [Float, nil]
      def initialize(model:, provider: nil, temperature: nil)
        @model = model
        @provider = provider
        @temperature = temperature
      end

      # @param input  [String, Hash]
      # @return [Hash] { output: String, usage: TokenUsage }
      def invoke(input, config: {})
        prompt, system = extract_prompt(input)
        chat = build_chat(system)
        response = chat.ask(prompt)
        usage = Phronomy::TokenUsage.from_tokens(response.tokens)
        {output: response.content, usage: usage}
      end

      # Compose with another Runnable using >>.
      #
      # @param other [#invoke]
      # @return [SequentialChain]
      def >>(other)
        SequentialChain.new(self, other)
      end

      private

      def build_chat(system = nil)
        opts = {model: @model}
        if @provider
          opts[:provider] = @provider
          opts[:assume_model_exists] = true
        end
        chat = RubyLLM.chat(**opts)
        chat.with_temperature(@temperature) if @temperature
        chat.with_instructions(system) if system
        chat
      end

      def extract_prompt(input)
        case input
        when String
          [input, nil]
        when Hash
          prompt = input[:prompt] || input[:message] || input[:query] || input[:input]
          raise ArgumentError, "LLMChain received a Hash without a :prompt key" unless prompt

          [prompt, input[:system]]
        else
          [input.to_s, nil]
        end
      end
    end
  end
end
