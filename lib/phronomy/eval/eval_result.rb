# frozen_string_literal: true

module Phronomy
  module Eval
    # An immutable record holding the outcome of evaluating one EvalCase.
    #
    # @!attribute eval_case [EvalCase]  the original sample
    # @!attribute actual    [String]    the callable's output
    # @!attribute score     [Float]     scorer-assigned value in [0.0, 1.0]
    # @!attribute usage     [Phronomy::TokenUsage, nil]
    # @!attribute latency_ms [Integer]  wall-clock time of the callable in ms
    EvalResult = Data.define(:eval_case, :actual, :score, :usage, :latency_ms) do
      # Returns true when the scorer assigned a perfect score of 1.0.
      def pass?
        score >= 1.0
      end
    end
  end
end
