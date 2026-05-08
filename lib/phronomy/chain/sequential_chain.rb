# frozen_string_literal: true

module Phronomy
  module Chain
    # A chain composed of two or more Runnable steps connected by >>.
    # Each step's output is passed as the input of the next step.
    #
    # @example
    #   chain = prompt_template >> llm_chain >> output_parser
    #   result = chain.invoke(variable: "value")
    class SequentialChain
      include Phronomy::Runnable

      # @param steps [Array<#invoke>]
      def initialize(*steps)
        @steps = steps.flatten
      end

      # @param input [Object]
      # @return [Object] output of the last step
      def invoke(input, config: {})
        @steps.reduce(input) { |acc, step| step.invoke(acc, config: config) }
      end

      # Compose with another Runnable, extending the chain.
      #
      # @param other [#invoke]
      # @return [SequentialChain]
      def >>(other)
        SequentialChain.new(*@steps, other)
      end
    end
  end
end
