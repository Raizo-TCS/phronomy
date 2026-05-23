# frozen_string_literal: true

# Benchmark: Context::Assembler#build
#
# Tests context assembly performance for varying numbers of messages and
# knowledge chunks. This path is exercised on every agent turn.

require "benchmark"
require_relative "../lib/phronomy"

BenchAsmMessage = Struct.new(:content)

def make_assembler(n_messages:, n_chunks:, with_budget: false)
  budget = if with_budget
    Phronomy::Context::TokenBudget.new(context_window: 4096, max_output_tokens: 512)
  end
  asm = Phronomy::Context::Assembler.new(budget: budget)
  asm.add_instruction("You are a helpful assistant. Answer the user's question.")
  n_chunks.times do |i|
    asm.add_knowledge("Fact #{i}: The capital of country #{i} is City #{i}.", type: :entity, trusted: true)
  end
  msgs = Array.new(n_messages) { BenchAsmMessage.new("This is a conversation message.") }
  asm.add_messages(msgs)
  asm
end

BENCH_ASM_ITERATIONS = 1_000

puts "=== bench_context_assembler ==="
Benchmark.bm(40) do |x|
  x.report("build(10 msgs, 0 chunks)") do
    BENCH_ASM_ITERATIONS.times { make_assembler(n_messages: 10, n_chunks: 0).build }
  end

  x.report("build(100 msgs, 5 chunks)") do
    BENCH_ASM_ITERATIONS.times { make_assembler(n_messages: 100, n_chunks: 5).build }
  end

  x.report("build(1000 msgs, 10 chunks, no budget)") do
    (BENCH_ASM_ITERATIONS / 10).times { make_assembler(n_messages: 1000, n_chunks: 10).build }
  end

  x.report("build(1000 msgs, 10 chunks, budgeted)") do
    (BENCH_ASM_ITERATIONS / 10).times { make_assembler(n_messages: 1000, n_chunks: 10, with_budget: true).build }
  end
end
