# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::VectorStore::InMemory do
  subject(:store) { described_class.new }

  # Contract tests: verify that InMemory satisfies the vector store interface (Issue #212).
  it_behaves_like "a vector store" do
    let(:store) { described_class.new(dimension: 3) }
  end

  describe "#add" do
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

    it "stores the embedding so the document can be retrieved by search" do
      store.add(id: "doc1", embedding: [1.0, 0.0], metadata: {text: "hello"})
      results = store.search(query_embedding: [1.0, 0.0], k: 1)
      expect(results.first[:id]).to eq("doc1")
    end

    it "stores the metadata and includes it in search results" do
      store.add(id: "doc1", embedding: [1.0, 0.0], metadata: {label: "test-label"})
      result = store.search(query_embedding: [1.0, 0.0], k: 1).first
      expect(result[:metadata][:label]).to eq("test-label")
    end

    it "defaults metadata to an empty hash when not supplied" do
      store.add(id: "doc1", embedding: [1.0, 0.0])
      result = store.search(query_embedding: [1.0, 0.0], k: 1).first
      expect(result[:metadata]).to eq({})
    end

    it "establishes the expected dimension from the first embedding added" do
      store.add(id: "1", embedding: [1.0, 0.0], metadata: {})
      expect {
        store.add(id: "2", embedding: [1.0, 0.0, 0.5], metadata: {})
      }.to raise_error(ArgumentError, /dimension mismatch/i)
    end

    it "raises CancellationError when the token is cancelled" do
      cancelled = Phronomy::CancellationToken.new.tap(&:cancel!)
      expect {
        store.add(id: "x", embedding: [1.0, 0.0], cancellation_token: cancelled)
      }.to raise_error(Phronomy::CancellationError)
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

    it "returns results in strictly descending score order" do
      results = store.search(query_embedding: [1.0, 0.0], k: 3)
      scores = results.map { |r| r[:score] }
      expect(scores).to eq(scores.sort.reverse)
      expect(scores.first).to be > scores.last
    end

    it "returns k=5 results by default when the store has 6 documents" do
      store.add(id: "d", embedding: [0.9, 0.1], metadata: {})
      store.add(id: "e", embedding: [0.8, 0.2], metadata: {})
      store.add(id: "f", embedding: [0.6, 0.4], metadata: {})
      results = store.search(query_embedding: [1.0, 0.0])
      expect(results.length).to eq(5)
    end

    it "raises ArgumentError when k is zero" do
      expect { store.search(query_embedding: [1.0, 0.0], k: 0) }
        .to raise_error(ArgumentError)
    end

    it "raises ArgumentError when k is negative" do
      expect { store.search(query_embedding: [1.0, 0.0], k: -1) }
        .to raise_error(ArgumentError)
    end

    it "raises CancellationError when the token is cancelled" do
      cancelled = Phronomy::CancellationToken.new.tap(&:cancel!)
      expect {
        store.search(query_embedding: [1.0, 0.0], cancellation_token: cancelled)
      }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "#cosine_similarity" do
    # Tests via the public #search interface since cosine_similarity is private.
    subject(:cs_store) { described_class.new }

    it "returns 1.0 for two identical unit vectors" do
      cs_store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
      result = cs_store.search(query_embedding: [1.0, 0.0], k: 1).first
      expect(result[:score]).to eq(1.0)
    end

    it "returns the exact cosine score for non-unit-norm vectors" do
      # [3,4] vs [4,3]: dot=3*4+4*3=24, |[3,4]|=5, |[4,3]|=5. cos=24/25=0.96
      cs_store.add(id: "a", embedding: [4.0, 3.0], metadata: {})
      result = cs_store.search(query_embedding: [3.0, 4.0], k: 1).first
      expect(result[:score]).to be_within(0.0001).of(0.96)
    end

    it "returns 0.0 when the stored document has a zero-norm embedding" do
      cs_store.add(id: "zero", embedding: [0.0, 0.0], metadata: {})
      cs_store.add(id: "normal", embedding: [1.0, 0.0], metadata: {})
      result = cs_store.search(query_embedding: [1.0, 0.0], k: 5).find { |r| r[:id] == "zero" }
      expect(result[:score]).to eq(0.0)
    end

    it "returns 0.0 when the query has a zero-norm embedding" do
      cs_store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
      results = cs_store.search(query_embedding: [0.0, 0.0], k: 5)
      results.each { |r| expect(r[:score]).to eq(0.0) }
    end

    it "returns 0.0 for empty (dimension-0) embeddings" do
      empty_cs = described_class.new(dimension: 0)
      empty_cs.add(id: "e", embedding: [], metadata: {})
      result = empty_cs.search(query_embedding: [], k: 1).first
      expect(result[:score]).to eq(0.0)
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

  describe "CancellationToken propagation (#242)" do
    let(:cancelled_token) { Phronomy::CancellationToken.new.tap(&:cancel!) }

    it "#add raises CancellationError when token is cancelled" do
      expect { store.add(id: "x", embedding: [1.0, 0.0], cancellation_token: cancelled_token) }
        .to raise_error(Phronomy::CancellationError)
    end

    it "#search raises CancellationError when token is cancelled" do
      expect { store.search(query_embedding: [1.0, 0.0], cancellation_token: cancelled_token) }
        .to raise_error(Phronomy::CancellationError)
    end
  end
end
