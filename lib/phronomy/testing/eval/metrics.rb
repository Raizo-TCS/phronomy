# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      class Metrics
        def initialize(results)
          @results = results
        end

        def pass_rate
          return 0.0 if @results.empty?
          @results.count(&:pass?).to_f / @results.size
        end

        def average_score
          return 0.0 if @results.empty?
          @results.sum(&:score) / @results.size
        end

        def total_usage
          @results.map(&:usage).compact.reduce(Phronomy::TokenUsage.zero, :+)
        end

        def average_latency_ms
          return 0.0 if @results.empty?
          @results.sum(&:latency_ms).to_f / @results.size
        end

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
end
