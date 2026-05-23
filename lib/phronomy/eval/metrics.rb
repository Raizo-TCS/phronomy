# frozen_string_literal: true

module Phronomy
  module Eval
    # Aggregates a collection of EvalResult objects into summary statistics.
    #
    # @example
    #   metrics = Metrics.new(results)
    #   puts metrics.pass_rate        # => 0.8
    #   puts metrics.average_score    # => 0.9
    #   puts metrics.to_h
    class Metrics
      # @param results [Array<EvalResult>]
      # @api public
      def initialize(results)
        @results = results
      end

      # Fraction of results that passed (score == 1.0).
      # @return [Float] in [0.0, 1.0]
      # @api public
      def pass_rate
        return 0.0 if @results.empty?
        @results.count(&:pass?).to_f / @results.size
      end

      # Arithmetic mean of all scores.
      # @return [Float]
      # @api public
      def average_score
        return 0.0 if @results.empty?
        @results.sum(&:score) / @results.size
      end

      # Sum of all TokenUsage objects present in the results.
      # Results without usage are skipped.
      # @return [Phronomy::TokenUsage]
      # @api public
      def total_usage
        @results.map(&:usage).compact.reduce(TokenUsage.zero, :+)
      end

      # Arithmetic mean of latency_ms across all results.
      # @return [Float]
      # @api public
      def average_latency_ms
        return 0.0 if @results.empty?
        @results.sum(&:latency_ms).to_f / @results.size
      end

      # Returns a plain Hash summary suitable for logging or serialisation.
      # @return [Hash]
      # @api public
      def to_h
        {
          total: @results.size,
          pass_count: @results.count(&:pass?),
          pass_rate: pass_rate,
          average_score: average_score,
          total_usage: total_usage.to_h,
          average_latency_ms: average_latency_ms
        }
      end
    end
  end
end
