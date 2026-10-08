# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "VectorStore framework contract" do
  let(:backend_class) do
    Class.new(Phronomy::VectorStore::Base) do
      attr_reader :writes
      attr_accessor :results, :count

      def initialize
        @writes = []
        @results = []
        @count = 0
      end

      protected

      def embedding_dimension = 2

      def perform_add(**attributes)
        @writes << attributes
        :backend_return_value
      end

      def perform_search(**) = @results
      def perform_size = @count
      def perform_remove(id:) = @writes << [:remove, id]
      def perform_clear = @writes << :clear
    end
  end
  let(:store) { backend_class.new }
  let(:row) { {id: "doc", score: 0.8, metadata: {text: "match"}} }

  it "supplies the public operation to a backend that implements only the storage hook" do
    vector = [1, 2]
    expect(store.add(id: "doc", embedding: vector)).to equal(store)
    expect(store.writes.first[:embedding]).to eq([1.0, 2.0])
    expect(store.writes.first[:embedding]).not_to equal(vector)
    expect(backend_class.instance_method(:add).owner).to eq(Phronomy::VectorStore::Base)
    expect(store).not_to respond_to(:perform_add)
  end

  [nil, "vector", [Float::NAN, 1], [Float::INFINITY, 1], [Complex(1, 2), 1], ["1", 2], [1]].each do |input|
    it "rejects #{input.inspect} before any backend write" do
      expect { store.add(id: "doc", embedding: input) }.to raise_error(ArgumentError)
      expect(store.writes).to be_empty
    end
  end

  it "checks cancellation before validation or a backend side effect" do
    cancelled = RuntimeError.new("cancelled")
    signal = double(raise_if_cancelled!: nil)
    allow(signal).to receive(:raise_if_cancelled!).and_raise(cancelled)
    expect { store.add(id: nil, embedding: nil, cancellation_token: signal) }
      .to raise_error { |error| expect(error).to equal(cancelled) }
    expect(store.writes).to be_empty
  end

  it "rejects bad id and metadata before writing" do
    expect { store.add(id: 1, embedding: [1, 2]) }.to raise_error(ArgumentError)
    expect { store.add(id: "doc", embedding: [1, 2], metadata: []) }.to raise_error(ArgumentError)
    expect { store.remove(id: 1) }.to raise_error(ArgumentError)
    expect(store.writes).to be_empty
  end

  it "passes a decimal k as an integer to the backend" do
    expect(store).to receive(:perform_search).with(query_embedding: [1.0, 2.0], k: 8, cancellation_token: nil).and_return([])
    expect(store.search(query_embedding: [1, 2], k: "08")).to eq([])
  end

  [0, -1, 1.5, "1.5", "not an integer", nil].each do |k|
    it "rejects invalid k #{k.inspect} before a search" do
      expect(store).not_to receive(:perform_search)
      expect { store.search(query_embedding: [1, 2], k: k) }.to raise_error(ArgumentError)
    end
  end

  it "validates result shape, score finiteness, ordering and result limit" do
    invalid = [nil, {}, [row.merge(id: 1)], [row.merge(metadata: nil)],
      [row.merge(score: Float::NAN)], [row.merge(score: Float::INFINITY)],
      [row, row.merge(score: 0.9)], [row, row, row]]
    invalid.each do |results|
      store.results = results
      expect { store.search(query_embedding: [1, 2], k: 2) }
        .to raise_error(Phronomy::VectorStore::InvalidResultError)
    end
  end

  it "preserves valid results and propagates backend exceptions without retry" do
    store.results = [row]
    expect(store.search(query_embedding: [1, 2])).to equal(store.results)
    failure = IOError.new("transport failed")
    expect(store).to receive(:perform_search).once.and_raise(failure)
    expect { store.search(query_embedding: [1, 2]) }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "provides remove/clear chaining and rejects a false count" do
    expect(store.remove(id: "doc")).to equal(store)
    expect(store.clear).to equal(store)
    expect(store.writes).to eq([[:remove, "doc"], :clear])
    [nil, -1, "3", 1.5].each do |count|
      store.count = count
      expect { store.size }.to raise_error(Phronomy::VectorStore::InvalidResultError)
    end
  end

  it "rejects invalid input even when RedisSearch has no index" do
    allow_any_instance_of(Phronomy::VectorStore::RedisSearch).to receive(:require).with("redis")
    redis = double("redis")
    expect(redis).not_to receive(:call)
    empty = Phronomy::VectorStore::RedisSearch.new(redis: redis)
    expect { empty.search(query_embedding: [1], k: 0) }.to raise_error(ArgumentError)
    expect { empty.add(id: "bad", embedding: [Float::NAN]) }.to raise_error(ArgumentError)
    expect(empty.instance_variable_get(:@dimension)).to be_nil
  end

  it "does not turn Redis count failures into a successful zero count" do
    allow_any_instance_of(Phronomy::VectorStore::RedisSearch).to receive(:require).with("redis")
    redis = double("redis")
    allow(redis).to receive(:call).with("FT.CREATE", any_args)
    allow(redis).to receive(:call).with("HSET", any_args)
    store = Phronomy::VectorStore::RedisSearch.new(redis: redis, dimension: 2)
    store.add(id: "doc", embedding: [1, 2])
    error = IOError.new("connection lost")
    expect(redis).to receive(:call).with("FT.INFO", any_args).once.and_raise(error)
    expect { store.size }.to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "loads and executes the contracts without the product loader, SDK or Engine" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", <<~RUBY)
      require "phronomy/vector_store/base"
      require "phronomy/embeddings/base"
      backend = Class.new(Phronomy::VectorStore::Base) do
        protected
        def perform_search(**) = []
      end.new
      embedder = Class.new(Phronomy::Embeddings::Base) do
        protected
        def perform_embed(text, token = nil) = [1, 2]
      end.new
      abort unless backend.search(query_embedding: [1, 2]) == []
      abort unless embedder.embed("text") == [1.0, 2.0]
      abort if defined?(RubyLLM) || defined?(Phronomy::Runtime) || defined?(Phronomy::Execution)
      abort if $LOADED_FEATURES.any? { |path| path.include?("/backends/") || path.include?("/async/") }
    RUBY
    expect(status).to be_success, "#{stdout}\n#{stderr}"
  end
end
