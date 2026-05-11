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

  describe "#purge" do
    it "removes all messages for the thread" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "a"), make_msg(:assistant, "b")])
      manager.purge(thread_id: "t1")
      expect(manager.load(thread_id: "t1")).to eq([])
    end

    it "does not affect other threads" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "a")])
      manager.save(thread_id: "t2", messages: [make_msg(:user, "b")])
      manager.purge(thread_id: "t1")
      expect(manager.load(thread_id: "t2").length).to eq(1)
    end

    it "clears the retrieval index for the thread" do
      indexing_retrieval = double("retrieval")
      allow(indexing_retrieval).to receive(:select).and_return([])
      allow(indexing_retrieval).to receive(:index)
      expect(indexing_retrieval).to receive(:clear_index).with(thread_id: "t1")
      mgr = described_class.new(storage: storage, retrieval: indexing_retrieval)
      mgr.save(thread_id: "t1", messages: [make_msg(:user, "a")])
      mgr.purge(thread_id: "t1")
    end
  end

  describe "TTL filtering" do
    subject(:ttl_manager) { described_class.new(storage: storage, retrieval: retrieval, ttl: 60) }

    it "calls purge_older_than with the correct cutoff time on each load" do
      fake_storage = instance_double(Phronomy::Memory::Storage::InMemory)
      allow(fake_storage).to receive(:load).and_return([])
      allow(fake_storage).to receive(:load_raw).and_return([])
      allow(fake_storage).to receive(:load_compactions).and_return([])
      expect(fake_storage).to receive(:purge_older_than) do |thread_id:, older_than:|
        expect(thread_id).to eq("t1")
        expect(older_than).to be_within(2).of(Time.now - 60)
      end
      mgr = described_class.new(storage: fake_storage, retrieval: retrieval, ttl: 60)
      mgr.load(thread_id: "t1")
    end

    it "does not call purge_older_than when TTL is not configured" do
      fake_storage = instance_double(Phronomy::Memory::Storage::InMemory)
      allow(fake_storage).to receive(:load).and_return([])
      allow(fake_storage).to receive(:load_raw).and_return([])
      allow(fake_storage).to receive(:load_compactions).and_return([])
      expect(fake_storage).not_to receive(:purge_older_than)
      mgr = described_class.new(storage: fake_storage, retrieval: retrieval)
      mgr.load(thread_id: "t1")
    end

    it "returns messages saved within the TTL window" do
      ttl_manager.save(thread_id: "t1", messages: [make_msg(:user, "recent")])
      expect(ttl_manager.load(thread_id: "t1").map(&:content)).to include("recent")
    end

    it "does not filter messages when no TTL is configured" do
      manager.save(thread_id: "t1", messages: [make_msg(:user, "msg")])
      expect(manager.load(thread_id: "t1").map(&:content)).to include("msg")
    end
  end

  describe "SummaryMessage (S10)" do
    it "is a frozen Data value object" do
      sm = Phronomy::Memory::ConversationManager::SummaryMessage.new(role: :system, content: "sum")
      expect(sm).to be_a(Data)
      expect(sm.role).to eq(:system)
      expect(sm.content).to eq("sum")
    end
  end

  describe "append_new_messages concurrency (S06)" do
    it "does not raise when concurrent saves overlap" do
      msgs = (1..10).map { |i| make_msg(:user, "msg#{i}") }
      threads = 4.times.map do
        Thread.new { manager.save(thread_id: "t_concurrent", messages: msgs) }
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  # Regression tests for GitHub Issue #27 (ID-9):
  # ConversationManager#append_new_messages uses raw.length as starting_seq.
  # After purge_older_than removes entries, raw.length decreases and the next
  # append re-assigns seq numbers that were already used by the purged entries,
  # causing seq collisions or re-insertion of expired messages.
  describe "TTL purge seq number isolation (Issue #27 / ID-9)" do
    let(:storage) { Phronomy::Memory::Storage::InMemory.new }
    let(:retrieval) { Phronomy::Memory::Retrieval::Recent.new(k: 100) }
    subject(:ttl_manager) { described_class.new(storage: storage, retrieval: retrieval, ttl: 1) }

    it "does not re-insert expired messages after TTL purge" do
      past = Time.now - 100
      allow(Time).to receive(:now).and_return(past)

      msg_a = make_msg(:user, "expired message")
      ttl_manager.save(thread_id: "t1", messages: [msg_a])

      allow(Time).to receive(:now).and_call_original

      # Load triggers TTL purge — msg_a should be removed from raw store
      ttl_manager.load(thread_id: "t1")

      # Now a new message arrives; the caller passes full history [msg_a, msg_b]
      msg_b = make_msg(:assistant, "new message")
      ttl_manager.save(thread_id: "t1", messages: [msg_a, msg_b])

      raw = storage.load_raw(thread_id: "t1")
      raw_contents = raw.map { |e| e[:message].content }

      # expired message should NOT be re-inserted into raw store
      expect(raw_contents).not_to include("expired message")
    end

    it "assigns non-colliding seq numbers after TTL purge removes entries" do
      past = Time.now - 100
      allow(Time).to receive(:now).and_return(past)

      msgs = 3.times.map { |i| make_msg(:user, "msg#{i}") }
      ttl_manager.save(thread_id: "t1", messages: msgs)

      allow(Time).to receive(:now).and_call_original

      # Purge via load
      ttl_manager.load(thread_id: "t1")

      # Save a new fourth message; caller passes full history
      msg_new = make_msg(:assistant, "msg3")
      ttl_manager.save(thread_id: "t1", messages: msgs + [msg_new])

      raw = storage.load_raw(thread_id: "t1")
      seqs = raw.map { |e| e[:seq] }

      # All seq numbers in the current raw store must be unique
      expect(seqs).to eq(seqs.uniq)
    end
  end

  # ---------------------------------------------------------------------------
  # Regression tests for issue #44:
  # Concurrent saves to the same thread_id must not produce duplicate
  # compaction records.  Before the fix, compress_and_save ran outside the
  # mutex, allowing two threads to each read an empty compaction list and then
  # each write an overlapping compaction record.
  # ---------------------------------------------------------------------------
  describe "concurrent saves do not produce duplicate compaction records (issue #44)" do
    it "never writes overlapping compaction records under concurrent saves" do
      # A compressor that sleeps between the read and write stages to reliably
      # widen the race window.
      # Without the fix (compress_and_save outside the per-thread mutex):
      #   Two threads both call load_compactions, see an empty list, sleep, and
      #   both write a compaction record → overlapping compactions.
      # With the fix (compress_and_save inside the per-thread mutex):
      #   Only one thread at a time can run the full read-compute-write cycle,
      #   so the second thread sees the first thread's compaction and skips.
      sleep_compressor = Class.new(Phronomy::Memory::Compression::Base) do
        def compress(thread_id:, messages:, seq_offset: 0)
          return {messages: messages, compaction: nil} if messages.length < 2
          sleep(0.005) # Widen the race window so concurrent threads can both read
          {
            messages: [],
            compaction: {
              start_seq: seq_offset,
              end_seq: seq_offset + messages.length - 1,
              summary_text: "summary"
            }
          }
        end
      end.new

      concurrent_storage = Phronomy::Memory::Storage::InMemory.new
      concurrent_manager = described_class.new(
        storage: concurrent_storage,
        retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 10),
        compression: sleep_compressor
      )

      msgs = [make_msg(:user, "a"), make_msg(:assistant, "b"),
              make_msg(:user, "c"), make_msg(:assistant, "d")]

      # Run many threads all saving the same thread_id concurrently.
      threads = 10.times.map do
        Thread.new { concurrent_manager.save(thread_id: "concurrent-t1", messages: msgs) }
      end
      threads.each(&:join)

      compactions = concurrent_storage.load_compactions(thread_id: "concurrent-t1")

      # No two compaction records may cover an overlapping seq range.
      compactions.combination(2).each do |a, b|
        overlap = a[:start_seq] <= b[:end_seq] && b[:start_seq] <= a[:end_seq]
        expect(overlap).to be(false),
          "Found overlapping compactions: #{a.inspect} and #{b.inspect}"
      end
    end
  end
end
