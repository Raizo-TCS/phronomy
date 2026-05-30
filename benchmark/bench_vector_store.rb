# frozen_string_literal: true

# Benchmark: VectorStore::InMemory#search
#
# Tests search performance at different corpus sizes (100, 1000, 10_000 docs).
# Linear scan is expected; this benchmark establishes the scaling baseline.

require "benchmark"
require_relative "../lib/phronomy"

DIM = 64

def random_embedding(dim)
  Array.new(dim) { rand(-1.0..1.0) }
end

def populate(store, n)
  n.times do |i|
    store.add(id: "doc#{i}", embedding: random_embedding(DIM), metadata: {text: "Document #{i}"})
  end
end

QUERY = random_embedding(DIM)

# Use fewer iterations for larger corpora to keep total run time reasonable.
BENCH_VS_ITERS = {100 => 100, 1_000 => 20, 10_000 => 5}.freeze

puts "=== bench_vector_store_inmemory ==="
Benchmark.bm(35) do |x|
  [100, 1_000, 10_000].each do |n|
    store = Phronomy::Agent::Context::Knowledge::VectorStore::InMemory.new(dimension: DIM)
    populate(store, n)
    iters = BENCH_VS_ITERS[n]

    x.report("search(k=5, corpus=#{n}, iters=#{iters})") do
      iters.times { store.search(query_embedding: QUERY, k: 5) }
    end
  end
end
