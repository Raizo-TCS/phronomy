# frozen_string_literal: true

module Phronomy
  module Eval
    # Runs a Dataset through a callable and collects EvalResult objects.
    #
    # The callable must respond to +#call(input)+ and may return either:
    # * a plain +String+ — treated as the output; usage is nil
    # * a +Hash+ with +:output+ and optional +:usage+ (TokenUsage) keys
    #
    # @example With a simple proc
    #   runner  = Runner.new(scorer: Scorer::ExactMatch.new)
    #   dataset = Dataset.from_array([{ input: "2+2", expected: "4" }])
    #   results = runner.run(dataset, ->(input) { "4" })
    #
    # @example With a Phronomy agent
    #   agent   = MyAgent.new
    #   results = runner.run(dataset, ->(input) { agent.invoke(input) })
    class Runner
      # @param scorer [Scorer::Base] scorer used to evaluate each result
      # @api public
      def initialize(scorer: Scorer::ExactMatch.new)
        @scorer = scorer
      end

      # @param dataset     [Dataset]  collection of EvalCase objects
      # @param callable    [#call]    accepts a single String argument
      # @param concurrency [Integer]  number of parallel threads (default: 1, sequential)
      # @return [Array<EvalResult>]
      # @api public
      def run(dataset, callable, concurrency: 1)
        cases = dataset.to_a
        return cases.map { |eval_case| run_one(eval_case, callable) } if concurrency <= 1

        # Run cases in slices of +concurrency+ tasks. Each slice is joined
        # before the next starts, bounding peak task count to +concurrency+.
        # Writing to pre-allocated slots (one per task) is safe because each
        # task writes to a unique index and all tasks in a slice are joined
        # before the next slice begins.
        # Exceptions in worker tasks are collected and re-raised after all
        # tasks in the slice are joined, preventing orphaned tasks.
        results = Array.new(cases.length)
        cases.each_with_index.each_slice(concurrency) do |batch|
          errors = []
          errors_mu = Mutex.new
          tasks = batch.map do |eval_case, i|
            Phronomy::Runtime.instance.spawn(name: "eval-case-#{i}") do
              results[i] = run_one(eval_case, callable)
            rescue => e
              errors_mu.synchronize { errors << e }
            end
          end
          tasks.each(&:join)
          raise errors.first if errors.any?
        end
        results
      end

      private

      # Evaluate a single EvalCase with the given callable and return an EvalResult.
      def run_one(eval_case, callable)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        result = callable.call(eval_case.input)
        latency_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - t0

        actual, usage = extract(result)
        score, score_error = score_safely(@scorer, actual: actual, expected: eval_case.expected, input: eval_case.input)

        EvalResult.new(eval_case: eval_case, actual: actual, score: score, usage: usage, latency_ms: latency_ms, error: score_error)
      end

      # Normalises the callable's return value into [actual_string, usage_or_nil].
      def extract(result)
        if result.is_a?(Hash)
          [result[:output].to_s, result[:usage]]
        else
          [result.to_s, nil]
        end
      end

      # Calls the scorer and returns [score, error]. On failure, returns [0.0, exception].
      def score_safely(scorer, **kwargs)
        [scorer.score(**kwargs), nil]
      rescue => e
        [0.0, e]
      end
    end
  end
end
