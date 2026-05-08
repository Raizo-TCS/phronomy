# frozen_string_literal: true

module Phronomy
  module Eval
    # Runs the same Dataset against two callables (configuration A and B) and
    # packages the paired results for side-by-side comparison.
    #
    # @example
    #   cmp     = Comparison.new(scorer: Scorer::ExactMatch.new)
    #   pairs   = cmp.compare(dataset, callable_a, callable_b)
    #   pairs.each do |pair|
    #     puts "A=#{pair.result_a.score} B=#{pair.result_b.score}"
    #   end
    #
    #   # Aggregate each side independently
    #   Metrics.new(pairs.map(&:result_a)).to_h
    class Comparison
      # Holds the two EvalResults for a single EvalCase.
      ComparisonPair = Data.define(:eval_case, :result_a, :result_b)

      # @param scorer [Scorer::Base]
      def initialize(scorer: Scorer::ExactMatch.new)
        @scorer = scorer
      end

      # Evaluates both callables on every case in the dataset.
      #
      # @param dataset    [Dataset]
      # @param callable_a [#call]
      # @param callable_b [#call]
      # @return [Array<ComparisonPair>]
      def compare(dataset, callable_a, callable_b)
        runner_a = Runner.new(scorer: @scorer)
        runner_b = Runner.new(scorer: @scorer)

        results_a = runner_a.run(dataset, callable_a)
        results_b = runner_b.run(dataset, callable_b)

        results_a.zip(results_b).map do |a, b|
          ComparisonPair.new(eval_case: a.eval_case, result_a: a, result_b: b)
        end
      end
    end
  end
end
