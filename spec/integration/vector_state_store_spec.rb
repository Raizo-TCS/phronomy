# frozen_string_literal: true

require_relative "spec_helper"

# Group 8: VectorStore / StateStore
# Pairwise factors: vector_store_type × vector_store_search_k ×
#                   vector_store_similarity × state_store_type × redis_ttl
# Feasible cases: 12  (redis state_store cases are infeasible – no Redis in CI)
#
# All tests use fixed float vectors – no LLM or embedding endpoint required.
# :integration tag is kept for consistency with the other integration groups.

# Fixed unit vectors used across all test cases.
# VEC_A and VEC_A2 have high cosine similarity (~0.99).
# VEC_A and VEC_B are orthogonal (cosine similarity = 0.0).
VEC_A = [1.0, 0.0, 0.0].freeze
VEC_A2 = [0.9950371902099892, 0.09950371902099892, 0.0].freeze  # ~6° from VEC_A
VEC_B = [0.0, 1.0, 0.0].freeze

# Minimal Struct used as a state object for StateStore tests.
VSSState = Struct.new(:thread_id, :value, keyword_init: true)

RSpec.describe "Group 8: VectorStore / StateStore", :integration do
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------
  def build_vector_store
    Phronomy::VectorStore::InMemory.new
  end

  def build_state_store
    Phronomy::StateStore::InMemory.new
  end

  # ---------------------------------------------------------------------------
  # TC-001: in_memory, k=1, identical (score≈1.0), state=nil — baseline
  # ---------------------------------------------------------------------------
  describe "TC-001: InMemoryVectorStore; k=1; identical document (score=1.0); stateless" do
    it "returns the identical document with score=1.0" do
      store = build_vector_store
      store.add(id: "doc1", embedding: VEC_A, metadata: {text: "hello"})

      results = store.search(query_embedding: VEC_A, k: 1)

      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq("doc1")
      expect(results.first[:score]).to be_within(0.001).of(1.0)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: in_memory, default k, high similarity, state=in_memory
  # ---------------------------------------------------------------------------
  describe "TC-002: InMemoryVectorStore; default k; high-similarity results; in-memory state store" do
    it "returns results sorted descending by score and persists state" do
      store = build_vector_store
      state_store = build_state_store

      store.add(id: "a", embedding: VEC_A, metadata: {label: "exact"})
      store.add(id: "b", embedding: VEC_A2, metadata: {label: "close"})
      store.add(id: "c", embedding: VEC_B, metadata: {label: "far"})

      results = store.search(query_embedding: VEC_A)  # default k=5

      expect(results.size).to eq(3)
      expect(results.first[:score]).to be > results.last[:score]
      expect(results.first[:id]).to eq("a")

      state = VSSState.new(thread_id: "t-002", value: "stored")
      state_store.save(state)
      expect(state_store.load("t-002")&.value).to eq("stored")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: in_memory, k=1, empty_store → [], state=in_memory
  # ---------------------------------------------------------------------------
  describe "TC-004: InMemoryVectorStore; k=1; empty store → []; in-memory state store" do
    it "returns [] when the store is empty" do
      store = build_vector_store
      state_store = build_state_store

      expect(store.search(query_embedding: VEC_A, k: 1)).to eq([])

      state = VSSState.new(thread_id: "t-004", value: "data")
      state_store.save(state)
      expect(state_store.load("t-004")).not_to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: in_memory, k=1, orthogonal (score=0.0), state=nil
  # ---------------------------------------------------------------------------
  describe "TC-006: InMemoryVectorStore; k=1; orthogonal vector (score=0.0); stateless" do
    it "returns the orthogonal document with score=0.0" do
      store = build_vector_store
      store.add(id: "orth", embedding: VEC_B, metadata: {text: "orthogonal"})

      results = store.search(query_embedding: VEC_A, k: 1)

      expect(results.size).to eq(1)
      expect(results.first[:score]).to be_within(0.001).of(0.0)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: in_memory, default k, orthogonal, state=nil
  # ---------------------------------------------------------------------------
  describe "TC-008: InMemoryVectorStore; default k; all orthogonal vectors; stateless" do
    it "retrieves all documents even when all cosine scores are 0.0" do
      store = build_vector_store
      store.add(id: "x", embedding: VEC_B, metadata: {idx: 0})
      store.add(id: "y", embedding: VEC_B, metadata: {idx: 1})

      results = store.search(query_embedding: VEC_A)

      expect(results.size).to eq(2)
      results.each { |r| expect(r[:score]).to be_within(0.001).of(0.0) }
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: in_memory, default k, empty_store → [], state=nil
  # ---------------------------------------------------------------------------
  describe "TC-009: InMemoryVectorStore; default k; empty store → []; stateless" do
    it "returns [] when no documents have been added" do
      store = build_vector_store
      expect(store.search(query_embedding: VEC_A)).to eq([])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: in_memory, k exceeds count → all returned; identical; state=in_memory
  # ---------------------------------------------------------------------------
  describe "TC-010: InMemoryVectorStore; k > document count → all returned; identical; in-memory store" do
    it "returns all 3 documents without error when k=10 but only 3 stored" do
      store = build_vector_store
      state_store = build_state_store

      store.add(id: "1", embedding: VEC_A, metadata: {})
      store.add(id: "2", embedding: VEC_A2, metadata: {})
      store.add(id: "3", embedding: VEC_B, metadata: {})

      results = store.search(query_embedding: VEC_A, k: 10)

      expect(results.size).to eq(3)
      expect(results.first[:score]).to be_within(0.001).of(1.0)

      s = VSSState.new(thread_id: "t-010", value: "ok")
      state_store.save(s)
      expect(state_store.load("t-010")).not_to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: in_memory, k exceeds size, high similarity, state=nil
  # ---------------------------------------------------------------------------
  describe "TC-011: InMemoryVectorStore; k exceeds stored count; high similarity; stateless" do
    it "returns all stored documents without raising" do
      store = build_vector_store
      store.add(id: "p", embedding: VEC_A, metadata: {})
      store.add(id: "q", embedding: VEC_A2, metadata: {})

      results = store.search(query_embedding: VEC_A, k: 100)

      expect(results.size).to eq(2)
      expect(results.first[:score]).to be > 0.9
    end
  end

  # ---------------------------------------------------------------------------
  # TC-013: in_memory, k=1, identical (score=1.0), state=nil
  # ---------------------------------------------------------------------------
  describe "TC-013: InMemoryVectorStore; k=1; identical similarity; stateless; top-1 retrieval" do
    it "returns exactly the top-1 document with the highest score" do
      store = build_vector_store
      store.add(id: "top", embedding: VEC_A, metadata: {label: "first"})
      store.add(id: "near", embedding: VEC_A2, metadata: {label: "second"})

      results = store.search(query_embedding: VEC_A, k: 1)

      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq("top")
      expect(results.first[:score]).to be_within(0.001).of(1.0)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-014: in_memory, k=1, high similarity, state=nil
  # ---------------------------------------------------------------------------
  describe "TC-014: InMemoryVectorStore; k=1; high-similarity document; stateless" do
    it "returns the closest high-similarity document from two candidates" do
      store = build_vector_store
      store.add(id: "hi", embedding: VEC_A2, metadata: {})
      store.add(id: "far", embedding: VEC_B, metadata: {})

      results = store.search(query_embedding: VEC_A, k: 1)

      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq("hi")
      expect(results.first[:score]).to be > 0.9
    end
  end

  # ---------------------------------------------------------------------------
  # TC-015: in_memory, k=1, orthogonal (score=0.0), state=in_memory
  # ---------------------------------------------------------------------------
  describe "TC-015: InMemoryVectorStore; k=1; orthogonal; in-memory state store" do
    it "returns orthogonal document (score=0.0) and persists state" do
      store = build_vector_store
      state_store = build_state_store

      store.add(id: "orth2", embedding: VEC_B, metadata: {})

      results = store.search(query_embedding: VEC_A, k: 1)
      expect(results.first[:score]).to be_within(0.001).of(0.0)

      s = VSSState.new(thread_id: "t-015", value: "orth_state")
      state_store.save(s)
      expect(state_store.load("t-015")&.value).to eq("orth_state")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-016: in_memory, k=1, empty_store → [], state=nil
  # ---------------------------------------------------------------------------
  describe "TC-016: InMemoryVectorStore; k=1; empty store → []; stateless" do
    it "returns [] on empty store" do
      store = build_vector_store
      expect(store.search(query_embedding: VEC_A, k: 1)).to eq([])
    end
  end
end
