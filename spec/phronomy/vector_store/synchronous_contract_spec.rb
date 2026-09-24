# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Synchronous backend cancellation contract" do
  it "accepts a structural cancellation signal without Runtime or a CancellationToken wrapper" do
    calls = 0
    signal = Object.new
    signal.define_singleton_method(:raise_if_cancelled!) { |*_args|
      calls += 1
      nil
    }
    store = Phronomy::VectorStore::InMemory.new(dimension: 1)
    store.add(id: "doc", embedding: [1.0], cancellation_token: signal)
    expect(store.search(query_embedding: [1.0], cancellation_token: signal).first[:id]).to eq("doc")
    embedding = Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings.new
    allow(RubyLLM).to receive(:embed).with("query").and_return(double(vectors: [1.0]))
    expect(embedding.embed("query", signal)).to eq([1.0])
    expect(calls).to eq(3)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
  end

  it "propagates a structural signal's cancellation without invoking an embedding provider" do
    error = StandardError.new("custom cancellation")
    signal = Object.new
    signal.define_singleton_method(:raise_if_cancelled!) { |*_args| raise error }
    expect(RubyLLM).not_to receive(:embed)
    expect { Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings.new.embed("query", signal) }
      .to raise_error { |actual| expect(actual).to equal(error) }
  end

  it "keeps synchronous signatures free of execution-engine types and async return handles" do
    signature = File.read(File.expand_path("../../../sig/phronomy/extensions.rbs", __dir__))
    expect(signature).to include("_CancellationSignal?")
    expect(signature).not_to include("Concurrency::", "TaskResult", "_async:")
    expect(Phronomy::VectorStore::Base.public_instance_methods(false)).to contain_exactly(:add, :search, :remove, :clear, :size)
    expect(Phronomy::VectorStore::Embeddings::Base.public_instance_methods(false)).to eq([:embed])
  end
end
