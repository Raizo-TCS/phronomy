# frozen_string_literal: true

# bench_agent_invoke.rb — Agent#invoke framework overhead benchmark.
#
# Measures the per-invoke cost of the Phronomy::Agent::Base framework path
# (context assembly, filter checks, before_llm_input hooks, response handling)
# with a fully stubbed LLM. No network calls are made.
# Each sample invokes a fresh Agent once. Agent construction is outside the
# measured block; growing conversation history is a different workload.
#
# Scenarios:
#   1. Minimal agent (no tools, no persistent Knowledge) — baseline framework overhead.
#   2. Tool-aware agent with a registered stub Tool.

require "benchmark"
require_relative "../lib/phronomy"

# ---------------------------------------------------------------------------
# Shared stubs
# ---------------------------------------------------------------------------

# A stub backend that preserves the adapter's validation/cancellation template.
class BenchStubLLMAdapter < Phronomy::LLMAdapter::Base
  def initialize(response)
    @response = response
  end

  protected

  def perform_complete(request, cancellation_token:)
    @response
  end
end

# A stub tool that does nothing but conforms to the Tool::Base interface.
class BenchNullTool < Phronomy::Tool::Base
  description "No-op benchmark tool"
  param :x, type: :string, desc: "input"

  def execute(x:)
    "result:#{x}"
  end
end

# ---------------------------------------------------------------------------
# Agent classes
# ---------------------------------------------------------------------------

BENCH_RESP = Phronomy::LLMAdapter::Response.new(
  content: "benchmark complete",
  usage: Phronomy::LLMAdapter::TokenUsage.new(input: 5, output: 5, cached: 0, cache_creation: 0)
)

bench_minimal_class = Class.new(Phronomy::Agent::Base) do
  agent_definition id: "bench-minimal", version: 1
  model "stub-model"
end

bench_tool_class = Class.new(Phronomy::Agent::Base) do
  agent_definition id: "bench-tool", version: 1
  model "stub-model"
  tools(BenchNullTool => nil)
end

AGENT_INVOKE_ITERATIONS = 200

Phronomy.with_configuration do |config|
  config.llm_adapter = BenchStubLLMAdapter.new(BENCH_RESP)
  bench_agents_minimal = Array.new(AGENT_INVOKE_ITERATIONS) { bench_minimal_class.new }.freeze
  bench_agents_tools = Array.new(AGENT_INVOKE_ITERATIONS) { bench_tool_class.new }.freeze

  puts "=== bench_agent_invoke ==="
  Benchmark.bm(50) do |x|
    x.report("Agent#invoke — fresh, no tools, #{AGENT_INVOKE_ITERATIONS} iters") do
      bench_agents_minimal.each do |agent|
        agent.invoke("ping")
      end
    end

    x.report("Agent#invoke — fresh, tool-aware, #{AGENT_INVOKE_ITERATIONS} iters") do
      bench_agents_tools.each do |agent|
        agent.invoke("ping")
      end
    end
  end
end
puts
