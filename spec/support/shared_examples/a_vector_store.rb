# frozen_string_literal: true

# Contract tests for Phronomy::VectorStore::Base implementations (Issue #212).
#
# Usage:
#   it_behaves_like "a vector store" do
#     let(:store) { described_class.new(dimension: 3) }
#   end
RSpec.shared_examples "a vector store" do
  # Callers must supply a `store` let block pointing to a fresh instance.
  # The store must accept embeddings of dimension 3.
  #
  # Callers may also supply an `empty_store` let block pointing to a fresh
  # instance that is guaranteed to be empty (no documents added).  The default
  # creates a new instance via `store.class.new(dimension: 3)`, which works
  # for InMemory.  For real-backend stores (RedisSearch, Pgvector) that require
  # additional constructor arguments, override this let in the caller context.
  let(:empty_store) { store.class.new(dimension: 3) }

  describe "interface" do
    it "responds to #add" do
      expect(store).to respond_to(:add)
    end

    it "responds to #search" do
      expect(store).to respond_to(:search)
    end

    it "responds to #remove" do
      expect(store).to respond_to(:remove)
    end

    it "responds to #clear" do
      expect(store).to respond_to(:clear)
    end

    it "responds to #size" do
      expect(store).to respond_to(:size)
    end
  end

  describe "#add and #size" do
    it "starts empty" do
      expect(store.size).to eq(0)
    end

    it "increments size on each add" do
      store.add(id: "a", embedding: [1.0, 0.0, 0.0], metadata: {})
      store.add(id: "b", embedding: [0.0, 1.0, 0.0], metadata: {})
      expect(store.size).to eq(2)
    end

    it "returns self for method chaining" do
      result = store.add(id: "x", embedding: [1.0, 0.0, 0.0], metadata: {})
      expect(result).to eq(store)
    end
  end

  describe "#search" do
    before do
      store.add(id: "match", embedding: [1.0, 0.0, 0.0], metadata: {tag: "match"})
      store.add(id: "no-match", embedding: [0.0, 1.0, 0.0], metadata: {tag: "other"})
      store.add(id: "partial", embedding: [0.7, 0.7, 0.0], metadata: {tag: "partial"})
    end

    it "returns an Array" do
      result = store.search(query_embedding: [1.0, 0.0, 0.0], k: 3)
      expect(result).to be_an(Array)
    end

    it "limits results to k" do
      results = store.search(query_embedding: [1.0, 0.0, 0.0], k: 2)
      expect(results.length).to be <= 2
    end

    it "each result includes :id, :score, and :metadata keys" do
      result = store.search(query_embedding: [1.0, 0.0, 0.0], k: 1).first
      expect(result).to include(:id, :score, :metadata)
    end

    it "returns :score as a Float" do
      result = store.search(query_embedding: [1.0, 0.0, 0.0], k: 1).first
      expect(result[:score]).to be_a(Float)
    end

    it "returns the most similar document first" do
      results = store.search(query_embedding: [1.0, 0.0, 0.0], k: 3)
      expect(results.first[:id]).to eq("match")
    end

    it "returns results in descending score order" do
      results = store.search(query_embedding: [1.0, 0.0, 0.0], k: 3)
      scores = results.map { |r| r[:score] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it "returns an empty array when the store is empty" do
      expect(empty_store.search(query_embedding: [1.0, 0.0, 0.0])).to eq([])
    end
  end

  describe "#remove" do
    before do
      store.add(id: "keep", embedding: [1.0, 0.0, 0.0], metadata: {})
      store.add(id: "drop", embedding: [0.0, 1.0, 0.0], metadata: {})
    end

    it "decrements size by one" do
      expect { store.remove(id: "drop") }.to change(store, :size).by(-1)
    end

    it "removed document no longer appears in search results" do
      store.remove(id: "drop")
      ids = store.search(query_embedding: [0.0, 1.0, 0.0], k: 10).map { |r| r[:id] }
      expect(ids).not_to include("drop")
    end

    it "returns self for method chaining" do
      expect(store.remove(id: "keep")).to eq(store)
    end

    it "is a no-op for unknown ids" do
      expect { store.remove(id: "nonexistent") }.not_to raise_error
    end
  end

  describe "#clear" do
    it "resets size to 0" do
      store.add(id: "1", embedding: [1.0, 0.0, 0.0], metadata: {})
      store.clear
      expect(store.size).to eq(0)
    end

    it "returns self for method chaining" do
      expect(store.clear).to eq(store)
    end

    it "cleared store returns empty search results" do
      store.add(id: "1", embedding: [1.0, 0.0, 0.0], metadata: {})
      store.clear
      expect(store.search(query_embedding: [1.0, 0.0, 0.0])).to eq([])
    end
  end
end
