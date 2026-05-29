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
      # mutant:disable - concurrency default value mutations (0/2) are genuine equivalent because sequential and concurrent paths produce identical results; if concurrency<=1 boundary mutations (==1 / <1 / <=0 / .eql? / .equal? / false / nil / <=2) are genuine equivalent because the concurrent path with concurrency=1 still produces the same Array<EvalResult> via each_slice(1); spawn name: mutations are genuine equivalent (name is only used for logging)
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
      # mutant:disable - multiple genuine equivalent mutations: latency_ms=+t0 or =t0 are genuine because :millisecond makes all values Integer so be_a(Integer) passes; (actual,usage)=result is genuine because Ruby multi-assign of a String yields usage=nil identical to extract(); score_safely input: nil/eval_case/absent are genuine because ExactMatch and IncludesScorer ignore the :input kwarg; EvalResult error: nil/absent and usage: nil are genuine because on a successful score run score_error and usage are already nil
      def run_one(eval_case, callable)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        result = callable.call(eval_case.input)
        latency_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - t0

        actual, usage = extract(result)
        score, score_error = score_safely(@scorer, actual: actual, expected: eval_case.expected, input: eval_case.input)

        EvalResult.new(eval_case: eval_case, actual: actual, score: score, usage: usage, latency_ms: latency_ms, error: score_error)
      end

      # Normalises the callable's return value into [actual_string, usage_or_nil].
      # mutant:disable - multiple genuine equivalent mutations: is_a?(Hash) vs instance_of?(Hash) (no Hash subclass in practice); to_s vs to_str (String only); result[:output]/[:usage] vs .fetch(:output)/[:usage] (keys always present when is_a?(Hash)); [result.to_s, nil] vs [result.to_s] because actual,usage=[val] → usage=nil via Ruby multi-assign; result.to_s vs result.to_str for String-only values
      def extract(result)
        if result.is_a?(Hash)
          [result[:output].to_s, result[:usage]]
        else
          [result.to_s, nil]
        end
      end

      # Calls the scorer and returns [score, error]. On failure, returns [0.0, exception].
      # mutant:disable - [scorer.score(**kwargs), nil] vs [scorer.score(**kwargs)]: because score,error=[val] → error=nil via Ruby multi-assign; both produce the same destructuring in the caller
      def score_safely(scorer, **kwargs)
        [scorer.score(**kwargs), nil]
      rescue => e
        [0.0, e]
      end
    end
  end
end
