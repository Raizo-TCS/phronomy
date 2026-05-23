# frozen_string_literal: true

# run_all.rb — Runs all Phronomy benchmarks in sequence.
#
# Usage:
#   ruby benchmark/run_all.rb
#
# In CI this script must complete within 30 seconds (smoke check only).
#
# Baseline management (nightly regression tracking):
#   BENCHMARK_WRITE_BASELINE=path/to/baseline.json — write current throughput
#     results from bench_regression.rb to a JSON baseline file.
#   BENCHMARK_BASELINE=path/to/baseline.json — compare current results against
#     the stored baseline; exit 1 if any metric regresses beyond the threshold.
#   BENCHMARK_REGRESSION_THRESHOLD — percentage allowed before failing (default 20).

require "benchmark"
require "json"

BENCH_DIR = __dir__
SCRIPTS = %w[
  bench_token_estimator.rb
  bench_context_assembler.rb
  bench_vector_store.rb
  bench_workflow.rb
  bench_tool_schema.rb
  bench_regression.rb
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

# CI smoke check: fail if total exceeds the allowed limit.
max_seconds = ENV.fetch("BENCHMARK_MAX_SECONDS", "60").to_i
if overall_elapsed > max_seconds
  warn "FAIL: benchmark suite exceeded #{max_seconds}s limit (took #{"%.1f" % overall_elapsed}s)"
  exit 1
end

puts "OK: completed in #{"%.1f" % overall_elapsed}s (limit: #{max_seconds}s)"

# ---------------------------------------------------------------------------
# Baseline management — only active when the relevant env vars are set.
# REGRESSION_RESULTS is defined in bench_regression.rb (loaded above).
# ---------------------------------------------------------------------------

write_path = ENV["BENCHMARK_WRITE_BASELINE"]
compare_path = ENV["BENCHMARK_BASELINE"]
threshold = ENV.fetch("BENCHMARK_REGRESSION_THRESHOLD", "20").to_f / 100.0

if write_path
  File.write(write_path, JSON.pretty_generate(REGRESSION_RESULTS))
  puts "\nBaseline written to #{write_path}"
end

if compare_path
  unless File.exist?(compare_path)
    warn "FAIL: baseline file not found: #{compare_path}"
    exit 1
  end

  baseline = JSON.parse(File.read(compare_path))
  regressions = []

  puts "\n#{"=" * 60}"
  puts "Regression comparison (threshold: #{(threshold * 100).to_i}%)"
  printf("%-46s  %10s  %10s  %8s\n", "Metric", "Baseline", "Current", "Change")
  puts "-" * 78

  REGRESSION_RESULTS.each do |key, current_ips|
    unless baseline.key?(key)
      printf("%-46s  %10s  %10.0f  %8s\n", key, "N/A", current_ips, "new")
      next
    end

    baseline_ips = baseline[key].to_f
    change = (baseline_ips - current_ips) / baseline_ips  # positive = slower

    status = if change > threshold
      regressions << {key:, baseline: baseline_ips, current: current_ips, change:}
      "FAIL"
    elsif change > threshold * 0.5
      "WARN"
    else
      "OK"
    end

    printf("%-46s  %10.0f  %10.0f  %+7.1f%%  %s\n",
      key, baseline_ips, current_ips, -change * 100, status)
  end

  if regressions.any?
    puts
    warn "FAIL: #{regressions.size} benchmark(s) regressed beyond #{(threshold * 100).to_i}%:"
    regressions.each do |r|
      warn "  #{r[:key]}: #{r[:baseline].round} → #{r[:current].round} iter/s " \
           "(#{format("%+.1f%%", -r[:change] * 100)})"
    end
    exit 1
  else
    puts "\nAll benchmarks within threshold."
  end
end
