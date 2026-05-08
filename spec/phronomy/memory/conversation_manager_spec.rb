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

  describe "raw message preservation" do
    it "appends all saved messages to the raw store" do
      msgs = [make_msg(:user, "a"), make_msg(:assistant, "b"), make_msg(:user, "c")]
      manager.save(thread_id: "t1", messages: msgs)
      raw = storage.load_raw(thread_id: "t1")
      expect(raw.length).to eq(3)
      expect(raw.map { |r| r[:seq] }).to eq([0, 1, 2])
      expect(raw.map { |r| r[:message].content }).to eq(%w[a b c])
    end

    it "only appends truly new messages on subsequent saves" do
      msgs1 = [make_msg(:user, "a"), make_msg(:assistant, "b")]
      msgs2 = msgs1 + [make_msg(:user, "c")]
      manager.save(thread_id: "t1", messages: msgs1)
      manager.save(thread_id: "t1", messages: msgs2)
      raw = storage.load_raw(thread_id: "t1")
      # Should have 3 entries with seq 0..2, not 5 (no duplicate appends).
      expect(raw.length).to eq(3)
      expect(raw.map { |r| r[:seq] }).to eq([0, 1, 2])
    end

    it "does not append anything on a redundant save of the same messages" do
      msgs = [make_msg(:user, "a")]
      manager.save(thread_id: "t1", messages: msgs)
      manager.save(thread_id: "t1", messages: msgs)
      expect(storage.load_raw(thread_id: "t1").length).to eq(1)
    end

    it "isolates raw stores by thread" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "x")])
      manager.save(thread_id: "t2", messages: [make_msg(:user, "y"), make_msg(:assistant, "z")])
      expect(storage.load_raw(thread_id: "t1").length).to eq(1)
      expect(storage.load_raw(thread_id: "t2").length).to eq(2)
    end

    it "raw store is cleared on #clear" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "a")])
      manager.clear(thread_id: "t1")
      expect(storage.load_raw(thread_id: "t1")).to eq([])
    end
  end

  describe "compaction record saving" do
    # Stub a compressor that always fires compaction.
    let(:mock_compressor) do
      dbl = double("compressor")
      allow(dbl).to receive(:compress) do |thread_id:, messages:, seq_offset: 0|
        {
          messages: [OpenStruct.new(role: :system, content: "summary")],
          compaction: {start_seq: seq_offset, end_seq: seq_offset + messages.length - 2, summary_text: "summary text"}
        }
      end
      dbl
    end

    subject(:compacting_manager) do
      described_class.new(storage: storage, retrieval: retrieval, compression: mock_compressor)
    end

    it "saves a compaction record when compress returns one" do
      msgs = [make_msg(:user, "a"), make_msg(:assistant, "b"), make_msg(:user, "c")]
      compacting_manager.save(thread_id: "t1", messages: msgs)
      records = storage.load_compactions(thread_id: "t1")
      expect(records.length).to eq(1)
      expect(records.first[:summary_text]).to eq("summary text")
    end

    it "does not save a compaction record when compress returns nil compaction" do
      msgs = [make_msg(:user, "a")]
      allow(mock_compressor).to receive(:compress).and_return({messages: msgs, compaction: nil})
      compacting_manager.save(thread_id: "t1", messages: msgs)
      expect(storage.load_compactions(thread_id: "t1")).to eq([])
    end
  end
end
