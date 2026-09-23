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

module BenchAgentMessage
  def self.assistant(content = "done")
    RubyLLM::Message.new(
      role: :assistant, content: content,
      tokens: RubyLLM::Tokens.new(input: 5, output: 5, cache_read: 0, cache_write: 0)
    )
  end
end

# A minimal stub Chat that returns a pre-built response immediately.
class BenchStubChat
  attr_reader :messages

  def initialize(response)
    @response = response
    @messages = []
  end

  def with_instructions(_, **_options) = self
  def with_tools(*) = self
  def with_temperature(_) = self
  def with_cache_instructions(_) = self
  def with_output_schema(_) = self
  def last_message = @response

  def after_message(&block)
    @after_message = block
    self
  end

  def ask(_)
    complete
  end

  def complete
    @messages << @response
    @after_message&.call(@response)
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

AGENT_INVOKE_ITERATIONS = 200
BENCH_AGENTS_MINIMAL = Array.new(AGENT_INVOKE_ITERATIONS) { bench_minimal_class.new }.freeze
BENCH_AGENTS_TOOLS = Array.new(AGENT_INVOKE_ITERATIONS) { bench_tool_class.new }.freeze

puts "=== bench_agent_invoke ==="
Benchmark.bm(50) do |x|
  x.report("Agent#invoke — fresh, no tools, #{AGENT_INVOKE_ITERATIONS} iters") do
    BENCH_AGENTS_MINIMAL.each do |agent|
      agent.invoke("ping")
    end
  end

  x.report("Agent#invoke — fresh, tool-aware, #{AGENT_INVOKE_ITERATIONS} iters") do
    BENCH_AGENTS_TOOLS.each do |agent|
      agent.invoke("ping")
    end
  end
end
puts
