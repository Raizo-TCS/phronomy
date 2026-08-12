# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      # Sequential test-only evaluator. Concurrency belongs to the subsystem
      # under test, not to the evaluation helper itself.
      class Runner
        def initialize(scorer: Scorer::ExactMatch.new)
          @scorer = scorer
        end

        def run(dataset, callable)
          dataset.to_a.map { |eval_case| run_one(eval_case, callable) }
        end

        private

        def run_one(eval_case, callable)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
          result = callable.call(eval_case.input)
          latency_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started_at
          actual, usage = extract(result)
          score, score_error = score_safely(
            @scorer,
            actual: actual,
            expected: eval_case.expected,
            input: eval_case.input
          )
          EvalResult.new(
            eval_case: eval_case,
            actual: actual,
            score: score,
            usage: usage,
            latency_ms: latency_ms,
            error: score_error
          )
        end

        def extract(result)
          result.is_a?(Hash) ? [result[:output].to_s, result[:usage]] : [result.to_s, nil]
        end

        def score_safely(scorer, **kwargs)
          [scorer.score(**kwargs), nil]
        rescue => error
          [0.0, error]
        end
      end
    end
  end
end
