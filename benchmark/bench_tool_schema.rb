# frozen_string_literal: true

# Benchmark: Tool::Base params_schema generation and static_knowledge_chunks cache
#
# Tool schema generation happens once per tool class (lazily memoised).
# static_knowledge_chunks is cached at the class level; cache-hit overhead
# should be negligible compared to cache-miss (which calls the knowledge source).

require "benchmark"
require_relative "../lib/phronomy"

# --- Tool schema ---

class BenchTool10Params < Phronomy::Agent::Context::Capability::Base
  description "A tool with 10 parameters for benchmarking purposes"
  param :param1, type: :string, desc: "First parameter"
  param :param2, type: :integer, desc: "Second parameter"
  param :param3, type: :number, desc: "Third parameter"
  param :param4, type: :boolean, desc: "Fourth parameter"
  param :param5, type: :string, desc: "Fifth parameter"
  param :param6, type: :string, desc: "Sixth parameter", required: false
  param :param7, type: :integer, desc: "Seventh parameter", required: false
  param :param8, type: :string, desc: "Eighth parameter", required: false
  param :param9, type: :string, desc: "Ninth parameter", required: false
  param :param10, type: :string, desc: "Tenth parameter", required: false

  def execute(**_)
    "ok"
  end
end

# Warm up memoisation
BenchTool10Params.params_schema_definition

BENCH_TOOL_ITERATIONS = 50_000

puts "=== bench_tool_schema ==="
Benchmark.bm(35) do |x|
  x.report("params_schema_definition (memoised, 10p)") do
    BENCH_TOOL_ITERATIONS.times { BenchTool10Params.params_schema_definition }
  end
end

# --- static_knowledge_chunks cache ---

class BenchKnowledgeSource < Phronomy::Agent::Context::Knowledge::Base
  def fetch(query: nil)
    [{content: "Cached knowledge fact.", type: :static}]
  end

  def static?
    true
  end
end

class BenchAgentWithKnowledge < Phronomy::Agent::Base
  model "gpt-4o-mini"
  static_knowledge BenchKnowledgeSource.new
end

# Warm up cache
BenchAgentWithKnowledge.static_knowledge_chunks

puts "\n=== bench_static_knowledge_cache ==="
Benchmark.bm(35) do |x|
  x.report("static_knowledge_chunks (hit)") do
    BENCH_TOOL_ITERATIONS.times { BenchAgentWithKnowledge.static_knowledge_chunks }
  end
end
