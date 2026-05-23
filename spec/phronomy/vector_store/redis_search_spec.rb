# frozen_string_literal: true

require "spec_helper"

# RedisSearch backend requires the redis gem and a Redis instance with RediSearch.
# Unit tests here mock the Redis client.

RSpec.describe Phronomy::VectorStore::RedisSearch do
  before do
    allow_any_instance_of(described_class).to receive(:require).with("redis")
  end

  let(:redis) { instance_double("Redis") }

  subject(:store) { described_class.new(redis: redis, index_name: "test_idx", dimension: 2) }

  # Shared helper: stub index creation so tests don't have to repeat it.
  def stub_index_create
    allow(redis).to receive(:call).with("FT.CREATE", any_args)
  end

  describe "#add" do
    it "creates index if needed and calls HSET with packed vector and JSON metadata" do
      stub_index_create
      expect(redis).to receive(:call).with(
        "HSET", "phronomy_doc:doc1",
        "embedding", [1.0, 0.0].pack("f*"),
        "metadata", '{"label":"A"}'
      )
      result = store.add(id: "doc1", embedding: [1.0, 0.0], metadata: {label: "A"})
      expect(result).to eq(store)
    end
  end

  describe "#search" do
    it "calls FT.SEARCH with KNN query and returns parsed results" do
      stub_index_create
      allow(redis).to receive(:call).with("FT.CREATE", any_args)
      # Simulated FT.SEARCH response: [count, key, [field, value, ...]]
      raw = [
        1,
        "phronomy_doc:doc1",
        ["score", "0.05", "metadata", '{"label":"A"}']
      ]
      expect(redis).to receive(:call).with("FT.SEARCH", any_args).and_return(raw)

      results = store.search(query_embedding: [1.0, 0.0], k: 1)
      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq("doc1")
      expect(results.first[:score]).to be_within(0.001).of(0.95) # 1.0 - 0.05
      expect(results.first[:metadata]).to eq({label: "A"})
    end

    it "returns empty array when FT.SEARCH returns nil" do
      stub_index_create
      allow(redis).to receive(:call).with("FT.SEARCH", any_args).and_return(nil)
      results = store.search(query_embedding: [1.0, 0.0], k: 1)
      expect(results).to eq([])
    end
  end

  describe "#clear" do
    it "calls FT.DROPINDEX DD and returns self" do
      expect(redis).to receive(:call).with("FT.DROPINDEX", "test_idx", "DD")
      expect(store.clear).to eq(store)
    end

    it "ignores 'Unknown Index name' errors and returns self" do
      allow(redis).to receive(:call)
        .with("FT.DROPINDEX", any_args)
        .and_raise(RuntimeError, "Unknown Index name")
      expect { store.clear }.not_to raise_error
    end
  end

  describe "#remove" do
    it "calls DEL with the prefixed key and returns self" do
      expect(redis).to receive(:call).with("DEL", "phronomy_doc:doc1")
      expect(store.remove(id: "doc1")).to eq(store)
    end
  end

  describe "inheritance" do
    it "inherits from Phronomy::VectorStore::Base" do
      expect(described_class.ancestors).to include(Phronomy::VectorStore::Base)
    end
  end

  describe "LoadError when redis gem is absent" do
    it "raises LoadError with a helpful message" do
      allow_any_instance_of(described_class).to receive(:require).with("redis").and_raise(LoadError)
      expect { described_class.new(redis: redis) }
        .to raise_error(LoadError, /redis gem/)
    end
  end

  describe "thread safety" do
    # Regression test for: VectorStore::RedisSearch#ensure_index! has no mutex
    # protecting @index_created.  A concurrent clear + add sequence can leave
    # @index_created = true even though the index has been dropped, causing
    # subsequent add/search calls to skip ensure_index! and fail.
    it "keeps @index_created = false when clear races with ensure_index!" do
      entered_create = Queue.new
      release_create = Queue.new

      allow(redis).to receive(:call).with("FT.CREATE", any_args) do
        entered_create << :in
        release_create.pop
      end
      allow(redis).to receive(:call).with("FT.DROPINDEX", any_args)
      allow(redis).to receive(:call).with("HSET", any_args)

      # add_thread enters ensure_index! and blocks inside FT.CREATE
      add_thread = Thread.new do
        store.add(id: "d1", embedding: [1.0, 0.0], metadata: {})
      end

      # Wait until add_thread is inside FT.CREATE (has passed the @index_created check)
      entered_create.pop

      # Run clear in a separate thread so we don't deadlock if a mutex is added
      clear_thread = Thread.new { store.clear }

      # Give clear_thread time to acquire any lock and run (or block waiting for mutex)
      sleep 0.02

      # Unblock FT.CREATE so add_thread can finish
      release_create << :go
      add_thread.join
      clear_thread.join

      # Invariant: after clear, @index_created must be false so that the next
      # add/search call recreates the index rather than using a non-existent one.
      expect(store.instance_variable_get(:@index_created)).to be(false)
    end
  end

  # Regression tests for Issue #98: embedding dimension validation
  describe "dimension validation (Issue #98)" do
    context "when dimension: is specified (existing behaviour)" do
      it "raises ArgumentError on add with wrong dimension" do
        expect { store.add(id: "x", embedding: [1.0, 0.0, 0.5], metadata: {}) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end

      it "raises ArgumentError on search with wrong dimension" do
        stub_index_create
        expect { store.search(query_embedding: [1.0, 0.0, 0.5]) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end
    end

    context "when dimension: is not specified" do
      subject(:store_no_dim) { described_class.new(redis: redis, index_name: "test_idx") }

      it "returns [] on search before first add (search never establishes dimension)" do
        expect(store_no_dim.search(query_embedding: [1.0, 0.0])).to eq([])
      end

      it "search does not establish dimension" do
        store_no_dim.search(query_embedding: [1.0, 0.0])
        expect(store_no_dim.instance_variable_get(:@dimension)).to be_nil
      end

      it "infers dimension from first add and validates subsequent adds" do
        stub_index_create
        allow(redis).to receive(:call).with("HSET", any_args)
        store_no_dim.add(id: "a", embedding: [1.0, 0.0], metadata: {})
        expect { store_no_dim.add(id: "b", embedding: [1.0, 0.0, 0.5], metadata: {}) }
          .to raise_error(ArgumentError, /dimension mismatch.*expected 2.*got 3/i)
      end
    end

    context "clear behaviour" do
      it "retains established dimension after clear" do
        allow(redis).to receive(:call).with("FT.DROPINDEX", any_args).and_raise(RuntimeError, "Unknown Index name")
        store.clear
        expect(store.instance_variable_get(:@dimension)).to eq(2)
      end
    end
  end

  describe "#size" do
    it "returns 0 before any add (index not created)" do
      expect(store.size).to eq(0)
    end

    it "queries FT.INFO after index is created" do
      stub_index_create
      allow(redis).to receive(:call).with("HSET", any_args)
      store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
      allow(redis).to receive(:call).with("FT.INFO", "test_idx")
        .and_return(["num_docs", "1", "other", "val"])
      expect(store.size).to eq(1)
    end

    it "returns 0 after clear" do
      stub_index_create
      allow(redis).to receive(:call).with("HSET", any_args)
      store.add(id: "a", embedding: [1.0, 0.0], metadata: {})
      allow(redis).to receive(:call).with("FT.DROPINDEX", any_args)
      store.clear
      expect(store.size).to eq(0)
    end
  end

  # Contract: structural expectations without a live backend.
  # Full data-operation contract runs in spec/integration/nightly/redis_search_spec.rb.
  describe "a_vector_store contract (live backend required)" do
    before { skip "Requires live Redis backend; see spec/integration/nightly/redis_search_spec.rb" }

    it_behaves_like "a vector store" do
      let(:store) { described_class.new(redis: redis, index_name: "test_idx", dimension: 3) }
      let(:empty_store) { described_class.new(redis: redis, index_name: "test_idx", dimension: nil) }
    end
  end
end
