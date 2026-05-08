# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::Storage::InMemory do
  subject(:storage) { described_class.new }

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  describe "#load" do
    it "returns empty array for unknown thread" do
      expect(storage.load(thread_id: "t1")).to eq([])
    end

    it "returns saved messages" do
      msgs = [make_msg(:user, "hi"), make_msg(:assistant, "hello")]
      storage.save(thread_id: "t1", messages: msgs)
      expect(storage.load(thread_id: "t1")).to eq(msgs)
    end

    it "returns a dup so mutations do not affect stored data" do
      msgs = [make_msg(:user, "hi")]
      storage.save(thread_id: "t1", messages: msgs)
      result = storage.load(thread_id: "t1")
      result << make_msg(:user, "extra")
      expect(storage.load(thread_id: "t1").length).to eq(1)
    end

    it "isolates threads" do
      storage.save(thread_id: "t1", messages: [make_msg(:user, "a")])
      storage.save(thread_id: "t2", messages: [make_msg(:user, "b")])
      expect(storage.load(thread_id: "t1").first.content).to eq("a")
      expect(storage.load(thread_id: "t2").first.content).to eq("b")
    end
  end

  describe "#save" do
    it "replaces existing messages" do
      storage.save(thread_id: "t1", messages: [make_msg(:user, "first")])
      storage.save(thread_id: "t1", messages: [make_msg(:user, "second")])
      expect(storage.load(thread_id: "t1").length).to eq(1)
      expect(storage.load(thread_id: "t1").first.content).to eq("second")
    end
  end

  describe "#clear" do
    it "removes messages for the thread" do
      storage.save(thread_id: "t1", messages: [make_msg(:user, "hi")])
      storage.clear(thread_id: "t1")
      expect(storage.load(thread_id: "t1")).to eq([])
    end

    it "does not affect other threads" do
      storage.save(thread_id: "t1", messages: [make_msg(:user, "a")])
      storage.save(thread_id: "t2", messages: [make_msg(:user, "b")])
      storage.clear(thread_id: "t1")
      expect(storage.load(thread_id: "t2").length).to eq(1)
    end

    it "also clears raw store and compaction store" do
      msgs = [make_msg(:user, "a"), make_msg(:assistant, "b")]
      storage.append_raw(thread_id: "t1", messages: msgs, starting_seq: 0)
      storage.save_compaction(thread_id: "t1", start_seq: 0, end_seq: 1, summary_text: "summary")
      storage.clear(thread_id: "t1")
      expect(storage.load_raw(thread_id: "t1")).to eq([])
      expect(storage.load_compactions(thread_id: "t1")).to eq([])
    end
  end

  describe "#append_raw and #load_raw" do
    it "returns empty array when no raw messages saved" do
      expect(storage.load_raw(thread_id: "t1")).to eq([])
    end

    it "appends messages with seq numbers starting at starting_seq" do
      msgs = [make_msg(:user, "first"), make_msg(:assistant, "second")]
      storage.append_raw(thread_id: "t1", messages: msgs, starting_seq: 0)
      raw = storage.load_raw(thread_id: "t1")
      expect(raw.length).to eq(2)
      expect(raw[0][:seq]).to eq(0)
      expect(raw[0][:message].content).to eq("first")
      expect(raw[1][:seq]).to eq(1)
      expect(raw[1][:message].content).to eq("second")
    end

    it "appends further messages with correct seq numbers" do
      msgs1 = [make_msg(:user, "a")]
      msgs2 = [make_msg(:assistant, "b"), make_msg(:user, "c")]
      storage.append_raw(thread_id: "t1", messages: msgs1, starting_seq: 0)
      storage.append_raw(thread_id: "t1", messages: msgs2, starting_seq: 1)
      raw = storage.load_raw(thread_id: "t1")
      expect(raw.map { |r| r[:seq] }).to eq([0, 1, 2])
    end

    it "isolates threads" do
      storage.append_raw(thread_id: "t1", messages: [make_msg(:user, "x")], starting_seq: 0)
      storage.append_raw(thread_id: "t2", messages: [make_msg(:user, "y")], starting_seq: 0)
      expect(storage.load_raw(thread_id: "t1").first[:message].content).to eq("x")
      expect(storage.load_raw(thread_id: "t2").first[:message].content).to eq("y")
    end

    it "returns a dup so mutations do not affect stored data" do
      storage.append_raw(thread_id: "t1", messages: [make_msg(:user, "hi")], starting_seq: 0)
      raw = storage.load_raw(thread_id: "t1")
      raw << {seq: 99, message: make_msg(:user, "intruder")}
      expect(storage.load_raw(thread_id: "t1").length).to eq(1)
    end
  end

  describe "#clear_raw" do
    it "removes raw messages for the thread" do
      storage.append_raw(thread_id: "t1", messages: [make_msg(:user, "a")], starting_seq: 0)
      storage.clear_raw(thread_id: "t1")
      expect(storage.load_raw(thread_id: "t1")).to eq([])
    end

    it "does not affect other threads" do
      storage.append_raw(thread_id: "t1", messages: [make_msg(:user, "a")], starting_seq: 0)
      storage.append_raw(thread_id: "t2", messages: [make_msg(:user, "b")], starting_seq: 0)
      storage.clear_raw(thread_id: "t1")
      expect(storage.load_raw(thread_id: "t2").length).to eq(1)
    end
  end

  describe "#save_compaction and #load_compactions" do
    it "returns empty array when no compactions saved" do
      expect(storage.load_compactions(thread_id: "t1")).to eq([])
    end

    it "saves and returns compaction records in order" do
      storage.save_compaction(thread_id: "t1", start_seq: 0, end_seq: 4, summary_text: "first summary")
      storage.save_compaction(thread_id: "t1", start_seq: 5, end_seq: 9, summary_text: "second summary")
      records = storage.load_compactions(thread_id: "t1")
      expect(records.length).to eq(2)
      expect(records[0]).to eq({start_seq: 0, end_seq: 4, summary_text: "first summary"})
      expect(records[1]).to eq({start_seq: 5, end_seq: 9, summary_text: "second summary"})
    end

    it "isolates threads" do
      storage.save_compaction(thread_id: "t1", start_seq: 0, end_seq: 3, summary_text: "for t1")
      expect(storage.load_compactions(thread_id: "t2")).to eq([])
    end

    it "returns a dup so mutations do not affect stored data" do
      storage.save_compaction(thread_id: "t1", start_seq: 0, end_seq: 3, summary_text: "s")
      records = storage.load_compactions(thread_id: "t1")
      records << {start_seq: 99, end_seq: 100, summary_text: "intruder"}
      expect(storage.load_compactions(thread_id: "t1").length).to eq(1)
    end
  end

  describe "#clear_compactions" do
    it "removes compaction records for the thread" do
      storage.save_compaction(thread_id: "t1", start_seq: 0, end_seq: 4, summary_text: "s")
      storage.clear_compactions(thread_id: "t1")
      expect(storage.load_compactions(thread_id: "t1")).to eq([])
    end

    it "does not affect other threads" do
      storage.save_compaction(thread_id: "t1", start_seq: 0, end_seq: 4, summary_text: "s1")
      storage.save_compaction(thread_id: "t2", start_seq: 0, end_seq: 4, summary_text: "s2")
      storage.clear_compactions(thread_id: "t1")
      expect(storage.load_compactions(thread_id: "t2").length).to eq(1)
    end
  end
end
