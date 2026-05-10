# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::Retrieval::Semantic do
  def make_msg(content)
    OpenStruct.new(role: :user, content: content)
  end

  let(:store) { Phronomy::VectorStore::InMemory.new }
  let(:embeddings) do
    stub = double("embeddings")
    allow(stub).to receive(:embed) { |text| [text.length.to_f, 0.0] }
    stub
  end
  subject(:retrieval) { described_class.new(embeddings: embeddings, store: store, k: 2) }

  describe "#index" do
    it "adds messages to the store and index" do
      msgs = [make_msg("hello"), make_msg("world")]
      retrieval.index(thread_id: "t1", messages: msgs)
      expect(store.size).to eq(2)
    end

    it "scopes ids to the given thread_id" do
      retrieval.index(thread_id: "t1", messages: [make_msg("a")])
      retrieval.index(thread_id: "t2", messages: [make_msg("b")])
      expect(store.size).to eq(2)
    end
  end

  describe "#clear_index" do
    before do
      retrieval.index(thread_id: "t1", messages: [make_msg("msg-a"), make_msg("msg-b")])
      retrieval.index(thread_id: "t2", messages: [make_msg("msg-c")])
    end

    it "removes only the target thread's entries from the store" do
      retrieval.clear_index(thread_id: "t1")
      expect(store.size).to eq(1)
    end

    it "preserves other threads' entries" do
      retrieval.clear_index(thread_id: "t1")
      # t2's entry must remain and be searchable
      results = store.search(query_embedding: embeddings.embed("msg-c"), k: 5)
      expect(results.map { |r| r[:metadata][:thread_id] }).to all(eq("t2"))
    end

    it "does not re-embed remaining messages" do
      # embed is called only during index; clear_index must not call embed again
      expect(embeddings).not_to receive(:embed)
      retrieval.clear_index(thread_id: "t1")
    end
  end

  describe "max_index_size eviction" do
    subject(:bounded_retrieval) do
      described_class.new(embeddings: embeddings, store: store, k: 10, max_index_size: 2)
    end

    it "evicts the oldest entry when the index exceeds max_index_size" do
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("first")])
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("second")])
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("third")])

      # Store should contain at most 2 entries (oldest evicted)
      expect(store.size).to eq(2)
    end

    it "keeps the most recent entries after eviction" do
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("alpha")])
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("beta")])
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("gamma")])

      results = bounded_retrieval.select([make_msg("gamma")], query: "gamma", thread_id: "t1")
      contents = results.map(&:content)
      expect(contents).to include("gamma")
      expect(contents).not_to include("alpha")
    end

    it "does not evict when under the limit" do
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("a")])
      bounded_retrieval.index(thread_id: "t1", messages: [make_msg("b")])
      expect(store.size).to eq(2)
    end
  end
end
