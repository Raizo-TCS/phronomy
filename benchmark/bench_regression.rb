# frozen_string_literal: true

# bench_regression.rb — Targeted regression benchmarks.
#
# Measures the five minimum regression targets defined in Issue #232:
#   1. WorkflowContext#merge throughput
#   2. Workflow.define (graph build) time
#   3. Tool::Base#params_schema generation (10 params)
#   4. Orchestrator#dispatch_parallel overhead (10 stub agents, no LLM)
#   5. CancellationToken#cancelled? throughput (shared token, 8 threads)
#
# Results are stored in a global REGRESSION_RESULTS hash (keyed by metric name,
# value = iterations per second) for use by run_all.rb baseline comparison.

require "benchmark"
require_relative "../lib/phronomy"

REGRESSION_ITERATIONS = 5_000

# ---------------------------------------------------------------------------
# Target 1: WorkflowContext#merge throughput
# ---------------------------------------------------------------------------
context_class = Class.new do
  include Phronomy::WorkflowContext

  field :value, type: :replace, default: -> { 0 }
  field :log, type: :append, default: -> { [] }
end

sample_ctx = context_class.new(value: 42, log: ["a"])

t1 = Benchmark.measure("WorkflowContext#merge") do
  REGRESSION_ITERATIONS.times { sample_ctx.merge(value: 99, log: "b") }
end

# ---------------------------------------------------------------------------
# Target 2: Workflow.define graph build time
# ---------------------------------------------------------------------------
BUILD_ITERATIONS = 1_000

t2 = Benchmark.measure("Workflow.define (5 states)") do
  BUILD_ITERATIONS.times do
    build_ctx = Class.new do
      include Phronomy::WorkflowContext

      field :x, type: :replace, default: -> { 0 }
    end
    Phronomy::Workflow.define(build_ctx) do
      initial :a
      %i[a b c d].each_with_index do |state, i|
        next_state = %i[a b c d e][i + 1]
        action = ->(s) { s.merge(x: s.x + 1) }
        self.state state, action: action
        transition from: state, to: next_state
      end
      self.state :e, action: ->(s) { s }
      transition from: :e, to: :__finish__
    end
  end
end

# ---------------------------------------------------------------------------
# Target 3: Tool::Base#params_schema generation (10 params)
# ---------------------------------------------------------------------------
tool_class = Class.new(Phronomy::Tool::Base) do
  description "Test tool with 10 params"
  param :p1, type: :string, desc: "param 1"
  param :p2, type: :string, desc: "param 2"
  param :p3, type: :string, desc: "param 3"
  param :p4, type: :string, desc: "param 4"
  param :p5, type: :string, desc: "param 5"
  param :p6, type: :string, desc: "param 6"
  param :p7, type: :string, desc: "param 7"
  param :p8, type: :string, desc: "param 8"
  param :p9, type: :string, desc: "param 9"
  param :p10, type: :string, desc: "param 10"

  def execute(**_kwargs)
    "ok"
  end
end

t3 = Benchmark.measure("Tool::Base#params_schema_definition (10 params)") do
  REGRESSION_ITERATIONS.times { tool_class.params_schema_definition }
end

# ---------------------------------------------------------------------------
# Target 4: Orchestrator#dispatch_parallel overhead (10 stub agents, no LLM)
# ---------------------------------------------------------------------------
stub_agent_class = Class.new(Phronomy::Agent::Base) do
  define_method(:invoke) do |_input, messages: [], thread_id: nil, config: {}|
    {output: "stub", messages: []}
  end
  define_method(:invoke_async) { |input, **_kw| Phronomy::Runtime.instance.spawn(name: "bench-stub") { invoke(input) } }
end

orchestrator_class = Class.new(Phronomy::Agent::Orchestrator)
orchestrator = orchestrator_class.new

PARALLEL_ITERATIONS = 200

t4 = Benchmark.measure("Orchestrator#dispatch_parallel (10 agents)") do
  PARALLEL_ITERATIONS.times do
    tasks = Array.new(10) { {agent: stub_agent_class, input: "x"} }
    orchestrator.dispatch_parallel(*tasks)
  end
end

# ---------------------------------------------------------------------------
# Target 5: CancellationToken#cancelled? throughput (8 threads)
# ---------------------------------------------------------------------------
CANCEL_TOKEN = Phronomy::CancellationToken.new
CANCEL_ITERATIONS = 10_000

t5 = Benchmark.measure("CancellationToken#cancelled? (8 threads)") do
  threads = 8.times.map do
    Thread.new { CANCEL_ITERATIONS.times { CANCEL_TOKEN.cancelled? } }
  end
  threads.each(&:join)
end

# ---------------------------------------------------------------------------
# Target 6: CancellationToken#raise_if_cancelled! hot path (no-op, single thread)
# ---------------------------------------------------------------------------
RAISE_TOKEN = Phronomy::CancellationToken.new  # not cancelled — no-op path
RAISE_ITERATIONS = 200_000

t6 = Benchmark.measure("CancellationToken#raise_if_cancelled! (no-op)") do
  RAISE_ITERATIONS.times { RAISE_TOKEN.raise_if_cancelled! }
end

# ---------------------------------------------------------------------------
# Target 7: Context::TrimContext#remove on a 2000-element history
# ---------------------------------------------------------------------------
BenchMsg = Struct.new(:content) unless defined?(BenchMsg)

TRIM_ELEMENTS = Array.new(2_000) { |i| {seq: i, message: BenchMsg.new("msg #{i}"), tokens: 10, role: :user} }
TRIM_BUDGET = Phronomy::Context::TokenBudget.new(context_window: 4096, max_output_tokens: 512)
TRIM_ITERATIONS = 500

t7 = Benchmark.measure("TrimContext#remove (2000-element history)") do
  TRIM_ITERATIONS.times do
    tc = Phronomy::Context::TrimContext.new(message_elements: TRIM_ELEMENTS, budget: TRIM_BUDGET)
    tc.remove((0...200).to_a)  # remove 200 oldest messages
  end
end

# ---------------------------------------------------------------------------
# Print results and store in REGRESSION_RESULTS
# ---------------------------------------------------------------------------
puts "=== bench_regression ==="
printf("%-46s  %8s  %12s\n", "Metric", "Real (s)", "Iter/s")
puts "-" * 70

metrics = {
  "workflow_context_merge" => [t1, REGRESSION_ITERATIONS],
  "workflow_define" => [t2, BUILD_ITERATIONS],
  "tool_params_schema_definition" => [t3, REGRESSION_ITERATIONS],
  "dispatch_parallel_10" => [t4, PARALLEL_ITERATIONS],
  "cancellation_token_cancelled" => [t5, 8 * CANCEL_ITERATIONS],
  "cancellation_token_raise_if_cancelled_noop" => [t6, RAISE_ITERATIONS],
  "trim_context_remove_2000" => [t7, TRIM_ITERATIONS]
}

REGRESSION_RESULTS = {} # rubocop:disable Style/MutableConstant

metrics.each do |key, (measure, iters)|
  ips = iters / measure.real
  REGRESSION_RESULTS[key] = ips
  printf("%-46s  %8.3f  %12.0f\n", key, measure.real, ips)
end
puts
