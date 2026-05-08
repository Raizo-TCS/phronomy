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
end
