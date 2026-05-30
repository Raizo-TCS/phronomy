# frozen_string_literal: true

# Benchmark: Context::TokenEstimator.estimate
#
# Tests estimation speed for short, medium, and long text inputs, and for
# Arrays of message-like objects. This method is called on every message in
# every agent turn, so it must be consistently fast.

require "benchmark"
require_relative "../lib/phronomy"

SHORT_TEXT = "Hello, how are you today?"
MEDIUM_TEXT = "A" * 500
LONG_TEXT = "A" * 10_000

BenchMessage = Struct.new(:content)

MESSAGES_100 = Array.new(100) { BenchMessage.new("A" * 100) }
MESSAGES_1000 = Array.new(1000) { BenchMessage.new("A" * 100) }

BENCH_TOKEN_ITERATIONS = 10_000

puts "=== bench_token_estimator ==="
Benchmark.bm(30) do |x|
  x.report("estimate(short text)") do
    BENCH_TOKEN_ITERATIONS.times { Phronomy::LlmContextWindow::TokenEstimator.estimate(SHORT_TEXT) }
  end

  x.report("estimate(medium text 500c)") do
    BENCH_TOKEN_ITERATIONS.times { Phronomy::LlmContextWindow::TokenEstimator.estimate(MEDIUM_TEXT) }
  end

  x.report("estimate(long text 10k c)") do
    BENCH_TOKEN_ITERATIONS.times { Phronomy::LlmContextWindow::TokenEstimator.estimate(LONG_TEXT) }
  end

  x.report("estimate(100 messages)") do
    BENCH_TOKEN_ITERATIONS.times { Phronomy::LlmContextWindow::TokenEstimator.estimate(MESSAGES_100) }
  end

  x.report("estimate(1000 messages)") do
    (BENCH_TOKEN_ITERATIONS / 10).times { Phronomy::LlmContextWindow::TokenEstimator.estimate(MESSAGES_1000) }
  end
end
