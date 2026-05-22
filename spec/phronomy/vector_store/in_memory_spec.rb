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

  describe "#remove" do
    it "removes only the specified document" do
      store.add(id: "1", embedding: [1.0, 0.0], metadata: {})
      store.add(id: "2", embedding: [0.0, 1.0], metadata: {})
      store.remove(id: "1")
      expect(store.size).to eq(1)
      results = store.search(query_embedding: [1.0, 0.0], k: 5)
      expect(results.map { |r| r[:id] }).not_to include("1")
    end

    it "returns self for chaining" do
      store.add(id: "x", embedding: [1.0], metadata: {})
      expect(store.remove(id: "x")).to eq(store)
    end

    it "is a no-op for unknown ids" do
      expect { store.remove(id: "nonexistent") }.not_to raise_error
    end
  end

  # Regression tests for Issue #47: @documents is not protected by a Mutex.
  # Under MRI the GIL reduces (but does not eliminate) the risk; under JRuby /
  # TruffleRuby (no GIL) this test will fail without synchronization.
  describe "concurrent access (Issue #47)" do
    it "does not raise errors when multiple threads add documents simultaneously" do
      threads = 20.times.map do |i|
        Thread.new { store.add(id: i.to_s, embedding: [rand, rand, rand], metadata: {i: i}) }
      end
      expect { threads.each(&:join) }.not_to raise_error
    end

    it "does not lose entries under concurrent adds from multiple threads" do
      threads = 20.times.map do |i|
        Thread.new { store.add(id: i.to_s, embedding: [rand, rand, rand], metadata: {i: i}) }
      end
      threads.each(&:join)
      expect(store.size).to eq(20)
    end

    it "does not raise errors when adds and searches interleave across threads" do
      10.times { |i| store.add(id: "seed-#{i}", embedding: [rand, rand, rand], metadata: {}) }

      writers = 10.times.map do |i|
        Thread.new { store.add(id: "w#{i}", embedding: [rand, rand, rand], metadata: {}) }
      end
      readers = 5.times.map do
        Thread.new { store.search(query_embedding: [0.5, 0.5, 0.5], k: 3) }
      end
      expect { (writers + readers).each(&:join) }.not_to raise_error
    end
  end

  # Regression tests for Issue #98: embedding dimension validation
  describe "dimension validation (Issue #98)" do
    context "when dimension: is specified in constructor" do
      subject(:store) { described_class.new(dimension: 2) }

      it "accepts add with matching dimension" do
        expect { store.add(id: "a", embedding: [1.0, 0.0], metadata: {}) }.not_to raise_error
      end

      it "raises ArgumentError on add with wrong dimension" do
        expect { store.add(id: "a", embedding: [1.0, 0.0, 0.5], metadata: {}) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end

      it "accepts search with matching dimension" do
        expect { store.search(query_embedding: [1.0, 0.0]) }.not_to raise_error
      end

      it "raises ArgumentError on search with wrong dimension" do
        expect { store.search(query_embedding: [1.0, 0.0, 0.5]) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end
    end

    context "when dimension: is not specified" do
      it "infers dimension from first add and validates subsequent adds" do
        store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
        expect { store.add(id: "b", embedding: [0.0, 1.0], metadata: {}) }.not_to raise_error
        expect { store.add(id: "c", embedding: [0.0, 1.0, 0.5], metadata: {}) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end

      it "does not raise on search before first add (dimension unknown)" do
        expect { store.search(query_embedding: [1.0, 0.0]) }.not_to raise_error
        expect(store.search(query_embedding: [1.0, 0.0])).to eq([])
      end

      it "search does not establish dimension" do
        store.search(query_embedding: [1.0, 0.0])
        expect(store.instance_variable_get(:@expected_dimension)).to be_nil
      end
    end

    context "clear behaviour" do
      subject(:store) { described_class.new }

      it "retains established dimension after clear" do
        store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
        store.clear
        expect(store.instance_variable_get(:@expected_dimension)).to eq(2)
      end

      it "rejects add with different dimension after clear" do
        store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
        store.clear
        expect { store.add(id: "b", embedding: [1.0, 0.0, 0.5], metadata: {}) }
          .to raise_error(ArgumentError, /dimension mismatch/i)
      end
    end

    context "k parameter validation" do
      subject(:store) do
        s = described_class.new
        s.add(id: "a", embedding: [1.0, 0.0], metadata: {})
        s
      end

      it "raises ArgumentError when k is 0" do
        expect { store.search(query_embedding: [1.0, 0.0], k: 0) }
          .to raise_error(ArgumentError, /positive integer/i)
      end

      it "raises ArgumentError when k is negative" do
        expect { store.search(query_embedding: [1.0, 0.0], k: -3) }
          .to raise_error(ArgumentError, /positive integer/i)
      end

      it "raises ArgumentError when k is a non-integer string" do
        expect { store.search(query_embedding: [1.0, 0.0], k: "abc") }
          .to raise_error(ArgumentError)
      end

      it "accepts a positive integer string for k" do
        results = store.search(query_embedding: [1.0, 0.0], k: "2")
        expect(results).to be_an(Array)
      end
    end
  end
end
