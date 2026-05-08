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
      def initialize(scorer: Scorer::ExactMatch.new)
        @scorer = scorer
      end

      # @param dataset  [Dataset]  collection of EvalCase objects
      # @param callable [#call]    accepts a single String argument
      # @return [Array<EvalResult>]
      def run(dataset, callable)
        dataset.map do |eval_case|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
          result = callable.call(eval_case.input)
          latency_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - t0

          actual, usage = extract(result)
          score = @scorer.score(actual: actual, expected: eval_case.expected, input: eval_case.input)

          EvalResult.new(eval_case: eval_case, actual: actual, score: score, usage: usage, latency_ms: latency_ms)
        end
      end

      private

      # Normalises the callable's return value into [actual_string, usage_or_nil].
      def extract(result)
        if result.is_a?(Hash)
          [result[:output].to_s, result[:usage]]
        else
          [result.to_s, nil]
        end
      end
    end
  end
end
