# frozen_string_literal: true

module Phronomy
  module Eval
    # An immutable record holding the outcome of evaluating one EvalCase.
    #
    # @!attribute eval_case  [EvalCase]  the original sample
    # @!attribute actual     [String]    the callable's output
    # @!attribute score      [Float]     scorer-assigned value in [0.0, 1.0]
    # @!attribute usage      [Phronomy::TokenUsage, nil]
    # @!attribute latency_ms [Integer]  wall-clock time of the callable in ms
    # @!attribute error      [Exception, nil] set when the scorer raised an exception
    EvalResult = Data.define(:eval_case, :actual, :score, :usage, :latency_ms, :error) do
      def initialize(eval_case:, actual:, score:, usage:, latency_ms:, error: nil)
        super
      end

      # Returns true when the scorer assigned a perfect score of 1.0.
      def pass?
        score >= 1.0
      end

      # Returns true when the scorer raised an exception.
      def scorer_error?
        !error.nil?
      end
    end
  end
end
