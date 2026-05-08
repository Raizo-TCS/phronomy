# frozen_string_literal: true

module Phronomy
  module Eval
    # Represents a single evaluation sample with an input, an expected output,
    # and optional freeform metadata.
    #
    # @example
    #   EvalCase.new(input: "What is 2+2?", expected: "4")
    #   EvalCase.new(input: "Hello", expected: "Hi", metadata: { difficulty: :easy })
    EvalCase = Data.define(:input, :expected, :metadata) do
      def initialize(input:, expected:, metadata: {})
        super
      end
    end
  end
end
