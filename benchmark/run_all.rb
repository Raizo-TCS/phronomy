# frozen_string_literal: true

# run_all.rb — Runs all Phronomy benchmarks in sequence.
#
# Usage:
#   ruby benchmark/run_all.rb
#
# In CI this script must complete within 30 seconds (smoke check only —
# no threshold enforcement except the workflow transition check in bench_workflow.rb).
#
# For nightly threshold regression checking, run with BENCHMARK_BASELINE=path/to/baseline.json
# to compare current timings against a stored baseline.

require "benchmark"
require "json"

BENCH_DIR = __dir__
SCRIPTS = %w[
  bench_token_estimator.rb
  bench_context_assembler.rb
  bench_vector_store.rb
  bench_workflow.rb
  bench_tool_schema.rb
].freeze

puts "Phronomy benchmark suite"
puts "Ruby #{RUBY_VERSION} on #{RUBY_PLATFORM}"
puts "=" * 60

overall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

SCRIPTS.each do |script|
  path = File.join(BENCH_DIR, script)
  puts
  load path
end

overall_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - overall_start
puts
puts "=" * 60
puts "Total elapsed: #{"%.2f" % overall_elapsed}s"

# CI smoke check: fail if total exceeds 30 seconds
max_seconds = ENV.fetch("BENCHMARK_MAX_SECONDS", "30").to_i
if overall_elapsed > max_seconds
  warn "FAIL: benchmark suite exceeded #{max_seconds}s limit (took #{"%.1f" % overall_elapsed}s)"
  exit 1
end

puts "OK: completed in #{"%.1f" % overall_elapsed}s (limit: #{max_seconds}s)"
