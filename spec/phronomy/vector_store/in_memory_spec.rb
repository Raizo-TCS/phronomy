# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::VectorStore::InMemory do
  subject(:store) { described_class.new }

  describe "#add and #size" do
    it "starts empty" do
      expect(store.size).to eq(0)
    end

    it "adds documents and increments size" do
      store.add(id: "1", embedding: [1.0, 0.0], metadata: {text: "a"})
      store.add(id: "2", embedding: [0.0, 1.0], metadata: {text: "b"})
      expect(store.size).to eq(2)
    end

    it "returns self for chaining" do
      expect(store.add(id: "x", embedding: [1.0])).to eq(store)
    end
  end

  describe "#search" do
    before do
      store.add(id: "a", embedding: [1.0, 0.0], metadata: {label: "A"})
      store.add(id: "b", embedding: [0.0, 1.0], metadata: {label: "B"})
      store.add(id: "c", embedding: [0.7, 0.7], metadata: {label: "C"})
    end

    it "returns results sorted by descending cosine similarity" do
      results = store.search(query_embedding: [1.0, 0.0], k: 3)
      expect(results.map { |r| r[:id] }.first).to eq("a")
    end

    it "limits results to k" do
      results = store.search(query_embedding: [1.0, 0.0], k: 2)
      expect(results.length).to eq(2)
    end

    it "returns score and metadata for each result" do
      result = store.search(query_embedding: [1.0, 0.0], k: 1).first
      expect(result[:score]).to be_a(Float)
      expect(result[:metadata]).to have_key(:label)
    end

    it "returns 0.0 for orthogonal vectors" do
      results = store.search(query_embedding: [1.0, 0.0], k: 3)
      b_result = results.find { |r| r[:id] == "b" }
      expect(b_result[:score]).to be_within(0.001).of(0.0)
    end

    it "returns empty for empty store" do
      empty_store = described_class.new
      expect(empty_store.search(query_embedding: [1.0, 0.0])).to eq([])
    end
  end

  describe "#clear" do
    it "removes all documents" do
      store.add(id: "1", embedding: [1.0], metadata: {})
      store.clear
      expect(store.size).to eq(0)
    end

    it "returns self" do
      expect(store.clear).to eq(store)
    end
  end
end
