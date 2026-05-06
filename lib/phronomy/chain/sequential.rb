# frozen_string_literal: true

module Phronomy
  module Chain
    # A pipeline that chains multiple Runnables in sequence.
    # The output of each step becomes the input of the next.
    class Sequential
      include Phronomy::Runnable

      def initialize(steps)
        @steps = steps
      end

      def invoke(input, config: {})
        @steps.reduce(input) { |result, step| step.invoke(result, config: config) }
      end

      def stream(input, config: {}, &block)
        # Only the final step streams; intermediate steps execute synchronously.
        *preceding, last = @steps
        intermediate = preceding.reduce(input) { |result, step| step.invoke(result, config: config) }
        last.stream(intermediate, config: config, &block)
      end

      # When composed with >>, flattens the steps rather than nesting.
      def >>(other)
        Phronomy::Chain::Sequential.new(@steps + [other])
      end
    end
  end
end
