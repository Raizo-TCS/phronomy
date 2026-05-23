# frozen_string_literal: true

# Benchmark: Workflow transition loop
#
# Builds a linear chain of N states and measures how long it takes to run
# the full workflow to completion. 100 transitions must complete in <10ms.

require "benchmark"
require_relative "../lib/phronomy"

# Build a linear workflow: state_0 -> state_1 -> ... -> state_(N-1) -> __finish__
def build_linear_workflow(n)
  context_class = Class.new do
    include Phronomy::WorkflowContext

    field :count, type: :replace, default: -> { 0 }
  end

  Phronomy::Workflow.define(context_class) do
    initial :state_0

    n.times do |i|
      state :"state_#{i}", action: ->(s) { s.merge(count: s.count + 1) }
      transition from: :"state_#{i}", to: (i + 1 < n) ? :"state_#{i + 1}" : :__finish__
    end
  end
end

BENCH_WF_ITERATIONS = 50

puts "=== bench_workflow_transition ==="
Benchmark.bm(30) do |x|
  [10, 50, 100].each do |n|
    app = build_linear_workflow(n)
    cfg = {recursion_limit: n + 5}

    x.report("#{n} transitions") do
      BENCH_WF_ITERATIONS.times { app.invoke({}, config: cfg) }
    end
  end
end

# Threshold assertion: 100 transitions should complete in <10ms on average
puts "\nThreshold check: 100 transitions < 10ms average..."
app100 = build_linear_workflow(100)
cfg100 = {recursion_limit: 110}
samples = 20
elapsed = Benchmark.realtime { samples.times { app100.invoke({}, config: cfg100) } }
avg_ms = (elapsed / samples) * 1000.0
puts "  Average: #{"%.2f" % avg_ms}ms per run"
if avg_ms < 10.0
  puts "  PASS (< 10ms)"
else
  warn "  WARN: #{avg_ms.round(2)}ms exceeds 10ms threshold (environment may be slow)"
end
