# frozen_string_literal: true

# bench_agent_invoke.rb — Agent#invoke framework overhead benchmark.
#
# Measures the per-invoke cost of the Phronomy::Agent::Base framework path
# (context assembly, filter checks, before_llm_input hooks, response handling)
# with a fully stubbed LLM. No network calls are made.
#
# Scenarios:
#   1. Minimal agent (no tools, no persistent Knowledge) — baseline framework overhead.
#   2. Tool-aware agent with a registered stub Tool.
#   3. Agent#stream setup latency (first-chunk time with stubbed stream).

require "benchmark"
require_relative "../lib/phronomy"

# ---------------------------------------------------------------------------
# Shared stubs
# ---------------------------------------------------------------------------

BenchAgentMessage = Struct.new(:role, :content, :tool_calls, :tokens) do
  def self.assistant(content = "done")
    new(:assistant, content, nil,
      Struct.new(:input, :output, :cached, :cache_creation).new(5, 5, 0, 0))
  end
end

# A minimal stub Chat that returns a pre-built response immediately.
class BenchStubChat
  attr_reader :messages

  def initialize(response)
    @response = response
    @messages = []
  end

  def with_instructions(_) = self
  def with_tool(_) = self
  def with_temperature(_) = self
  def with_cache_instructions(_) = self
  def with_output_schema(_) = self
  def on_tool_call(&) = self
  def before_tool_call(&) = self
  def last_message = @response

  def ask(_)
    @messages << @response
    @response
  end

  def stream(*)
    yield @response.content if block_given?
    @response
  end
end

# A stub tool that does nothing but conforms to the Tool::Base interface.
class BenchNullTool < Phronomy::Agent::Context::Capability::Base
  description "No-op benchmark tool"
  param :x, type: :string, desc: "input"

  def execute(x:)
    "result:#{x}"
  end
end

# ---------------------------------------------------------------------------
# Agent classes
# ---------------------------------------------------------------------------

BENCH_RESP = BenchAgentMessage.assistant("benchmark complete")
BENCH_RESP_CHAT = BenchStubChat.new(BENCH_RESP)

bench_minimal_class = Class.new(Phronomy::Agent::Base) do
  agent_definition id: "bench-minimal", version: 1
  model "stub-model"

  define_method(:build_chat) { |*| BenchStubChat.new(BENCH_RESP) }
end

bench_tool_class = Class.new(Phronomy::Agent::Base) do
  agent_definition id: "bench-tool", version: 1
  model "stub-model"
  tools(BenchNullTool => nil)

  define_method(:build_chat) { |*| BenchStubChat.new(BENCH_RESP) }
end

BENCH_AGENT_MINIMAL = bench_minimal_class.new
BENCH_AGENT_TOOLS = bench_tool_class.new

AGENT_INVOKE_ITERATIONS = 200

puts "=== bench_agent_invoke ==="
Benchmark.bm(50) do |x|
  x.report("Agent#invoke — minimal (no tools), #{AGENT_INVOKE_ITERATIONS} iters") do
    AGENT_INVOKE_ITERATIONS.times do
      BENCH_AGENT_MINIMAL.invoke("ping", thread_id: "bench-#{rand(1_000_000)}")
    end
  end

  x.report("Agent#invoke — tool-aware, #{AGENT_INVOKE_ITERATIONS} iters") do
    AGENT_INVOKE_ITERATIONS.times do
      BENCH_AGENT_TOOLS.invoke("ping", thread_id: "bench-#{rand(1_000_000)}")
    end
  end
end
puts
