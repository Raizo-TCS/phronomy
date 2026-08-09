# frozen_string_literal: true

# Benchmark: Tool::Base params_schema generation.
#
# Tool schema generation happens once per tool class and is lazily memoized.

require "benchmark"
require_relative "../lib/phronomy"

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

BenchTool10Params.params_schema_definition

BENCH_TOOL_ITERATIONS = 50_000

puts "=== bench_tool_schema ==="
Benchmark.bm(35) do |x|
  x.report("params_schema_definition (memoised, 10p)") do
    BENCH_TOOL_ITERATIONS.times { BenchTool10Params.params_schema_definition }
  end
end
