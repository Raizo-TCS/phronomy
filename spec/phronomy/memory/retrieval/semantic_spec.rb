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
end
