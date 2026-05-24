# frozen_string_literal: true

require "spec_helper"

# Nightly spec: VectorStore::RedisSearch against a real Redis Stack instance.
#
# Required environment variables:
#   REDIS_URL — e.g. redis://localhost:6379
#   NIGHTLY=1
#
# Run with: bundle exec rspec spec/integration/nightly/redis_search_spec.rb --tag nightly
# Note: requires gem install redis before running.
#
# This spec was introduced in: https://github.com/Raizo-TCS/phronomy/issues/238

if ENV["NIGHTLY"] && ENV["REDIS_URL"]
  begin
    require "redis"
  rescue LoadError => e
    warn "Skipping redis_search nightly spec: #{e.message}"
  end
end

REDIS_AVAILABLE = defined?(Redis) && ENV["REDIS_URL"]

RSpec.describe "Nightly: VectorStore::RedisSearch against real Redis Stack", :nightly, real_backend: :redis do
  let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379")) }
  let(:index_name) { "phronomy_nightly_#{SecureRandom.hex(4)}" }
  let(:store) do
    Phronomy::VectorStore::RedisSearch.new(
      redis: redis,
      index_name: index_name,
      dimension: 3
    )
  end

  before do
    skip "Skipped: REDIS_URL not set or redis gem missing" unless REDIS_AVAILABLE
  end

  after do
    # Clean up the index created during the test.

    redis.call("FT.DROPINDEX", index_name, "DD")
  rescue
    nil
  end

  it "adds a document and retrieves it via search" do
    store.add(id: "doc1", embedding: [0.9, 0.1, 0.0], metadata: {text: "hello"})
    results = store.search(query_embedding: [0.9, 0.1, 0.0], k: 1)
    expect(results.length).to eq(1)
    expect(results.first[:id]).to eq("doc1")
    expect(results.first[:metadata][:text]).to eq("hello")
    expect(results.first[:score]).to be_a(Float)
  end

  it "removes a document" do
    store.add(id: "rm1", embedding: [0.5, 0.5, 0.0], metadata: {})
    store.remove(id: "rm1")
    results = store.search(query_embedding: [0.5, 0.5, 0.0], k: 5)
    expect(results.map { |r| r[:id] }).not_to include("rm1")
  end

  it "clears all documents" do
    store.add(id: "cl1", embedding: [0.1, 0.2, 0.3], metadata: {})
    store.add(id: "cl2", embedding: [0.4, 0.5, 0.6], metadata: {})
    store.clear
    results = store.search(query_embedding: [0.1, 0.2, 0.3], k: 10)
    expect(results).to be_empty
  end

  it "returns results ordered by descending similarity" do
    store.add(id: "near", embedding: [1.0, 0.0, 0.0], metadata: {})
    store.add(id: "far", embedding: [0.0, 1.0, 0.0], metadata: {})
    results = store.search(query_embedding: [1.0, 0.0, 0.0], k: 2)
    expect(results.first[:id]).to eq("near")
    expect(results.last[:id]).to eq("far")
  end

  it "raises ArgumentError for dimension mismatch" do
    store.add(id: "seed", embedding: [0.1, 0.2, 0.3], metadata: {})
    expect {
      store.add(id: "bad", embedding: [1.0, 0.0], metadata: {})
    }.to raise_error(ArgumentError, /dimension/i)
  end

  # Contract tests: verify that RedisSearch satisfies the a_vector_store interface.
  # The outer before/after hooks handle backend availability checks and index cleanup.
  it_behaves_like "a vector store" do
    let(:empty_store) do
      # dimension: nil → search returns [] immediately before any index is created
      Phronomy::VectorStore::RedisSearch.new(
        redis: redis,
        index_name: index_name,
        dimension: nil
      )
    end
  end
end
