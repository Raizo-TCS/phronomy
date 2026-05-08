# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::ConversationManager do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:storage) { Phronomy::Memory::Storage::InMemory.new }
  let(:retrieval) { Phronomy::Memory::Retrieval::Recent.new(k: 3) }

  subject(:manager) { described_class.new(storage: storage, retrieval: retrieval) }

  describe "#load and #save" do
    let(:msgs) { (1..8).map { |i| make_msg(:user, "msg#{i}") } }

    it "returns empty array when no messages saved" do
      expect(manager.load(thread_id: "t1")).to eq([])
    end

    it "saves then loads selected messages" do
      manager.save(thread_id: "t1", messages: msgs)
      result = manager.load(thread_id: "t1")
      # Recent(k:3) selects last 6 from 8
      expect(result.length).to eq(6)
      expect(result.last.content).to eq("msg8")
    end

    it "isolates threads" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "a")])
      manager.save(thread_id: "t2", messages: [make_msg(:user, "b")])
      expect(manager.load(thread_id: "t1").first.content).to eq("a")
      expect(manager.load(thread_id: "t2").first.content).to eq("b")
    end
  end

  describe "#clear" do
    it "removes all messages for the thread" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "hi")])
      manager.clear(thread_id: "t1")
      expect(manager.load(thread_id: "t1")).to eq([])
    end
  end

  describe "with compression" do
    let(:compressor) { Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 5) }

    subject(:manager_with_compression) do
      described_class.new(storage: storage, retrieval: retrieval, compression: compressor)
    end

    it "applies compression before saving" do
      msgs = [
        make_msg(:user, "hi"),
        make_msg(:tool, "x" * 100)
      ]
      manager_with_compression.save(thread_id: "t1", messages: msgs)
      loaded = manager_with_compression.load(thread_id: "t1")
      tool_msg = loaded.find { |m| m.role.to_sym == :tool }
      expect(tool_msg.content).to include(Phronomy::Memory::Compression::ToolOutputPruner::TRUNCATION_NOTE)
    end
  end

  describe "with a retrieval strategy that supports indexing" do
    let(:embeddings) do
      dbl = double("embeddings")
      allow(dbl).to receive(:embed) { |text| Array.new(4) { rand } }
      dbl
    end
    let(:semantic_retrieval) { Phronomy::Memory::Retrieval::Semantic.new(embeddings: embeddings, k: 3) }

    subject(:semantic_manager) do
      described_class.new(storage: storage, retrieval: semantic_retrieval)
    end

    it "calls index on the retrieval strategy when saving" do
      msgs = [make_msg(:user, "hello")]
      expect(semantic_retrieval).to receive(:index).with(thread_id: "t1", messages: msgs).and_call_original
      semantic_manager.save(thread_id: "t1", messages: msgs)
    end

    it "calls clear_index on the retrieval strategy when clearing" do
      expect(semantic_retrieval).to receive(:clear_index).with(thread_id: "t1").and_call_original
      semantic_manager.clear(thread_id: "t1")
    end
  end
end
