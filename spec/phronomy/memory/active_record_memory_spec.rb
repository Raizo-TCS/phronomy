# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/active_record_setup"

RSpec.describe Phronomy::Memory::ActiveRecordMemory do
  # Use the real PhronomyMessageRecord model backed by in-memory SQLite.
  subject(:mem) { described_class.new(model_class: PhronomyMessageRecord) }

  # Truncate the table between each example for test isolation.
  before { PhronomyMessageRecord.delete_all }

  def make_msg(role, content, tool_calls: nil, model_id: nil)
    double("Message",
      role:       role,
      content:    content,
      tool_calls: tool_calls,
      model_id:   model_id)
  end

  # ---- #save_messages / #load_messages ----------------------------------------

  describe "#save_messages / #load_messages" do
    it "persists messages and retrieves them with matching role and content" do
      msgs = [make_msg(:user, "Hello"), make_msg(:assistant, "Hi!")]
      mem.save_messages(thread_id: "t1", messages: msgs)

      loaded = mem.load_messages(thread_id: "t1")
      expect(loaded.size).to eq(2)
      expect(loaded[0].role).to eq(:user)
      expect(loaded[0].content).to eq("Hello")
      expect(loaded[1].role).to eq(:assistant)
      expect(loaded[1].content).to eq("Hi!")
    end

    it "returns an empty array for a thread with no messages" do
      expect(mem.load_messages(thread_id: "empty")).to eq([])
    end

    it "replaces existing messages on re-save" do
      mem.save_messages(thread_id: "t1", messages: [make_msg(:user, "Old")])
      mem.save_messages(thread_id: "t1", messages: [make_msg(:user, "New")])
      expect(mem.load_messages(thread_id: "t1").first.content).to eq("New")
    end

    it "respects the limit option and returns the most recent messages" do
      msgs = (1..5).map { |i| make_msg(:user, "msg#{i}") }
      mem.save_messages(thread_id: "t1", messages: msgs)
      loaded = mem.load_messages(thread_id: "t1", limit: 3)
      expect(loaded.size).to eq(3)
      expect(loaded.last.content).to eq("msg5")
    end

    it "persists and restores tool_calls as a parsed structure" do
      tc = [{"name" => "search", "arguments" => {"query" => "ruby"}}]
      msg = make_msg(:assistant, "", tool_calls: tc)
      mem.save_messages(thread_id: "t1", messages: [msg])

      loaded = mem.load_messages(thread_id: "t1").first
      expect(loaded.tool_calls).to eq(tc)
    end

    it "stores nil tool_calls as nil" do
      mem.save_messages(thread_id: "t1", messages: [make_msg(:user, "Hi")])
      expect(mem.load_messages(thread_id: "t1").first.tool_calls).to be_nil
    end

    it "manages multiple threads independently" do
      mem.save_messages(thread_id: "t1", messages: [make_msg(:user, "T1")])
      mem.save_messages(thread_id: "t2", messages: [make_msg(:user, "T2")])
      expect(mem.load_messages(thread_id: "t1").first.content).to eq("T1")
      expect(mem.load_messages(thread_id: "t2").first.content).to eq("T2")
    end
  end

  # ---- #clear ----------------------------------------------------------------

  describe "#clear" do
    it "removes all messages for the given thread_id" do
      mem.save_messages(thread_id: "t1", messages: [make_msg(:user, "Hi")])
      mem.clear(thread_id: "t1")
      expect(mem.load_messages(thread_id: "t1")).to eq([])
    end

    it "does not affect other threads" do
      mem.save_messages(thread_id: "t1", messages: [make_msg(:user, "T1")])
      mem.save_messages(thread_id: "t2", messages: [make_msg(:user, "T2")])
      mem.clear(thread_id: "t1")
      expect(mem.load_messages(thread_id: "t2").first.content).to eq("T2")
    end
  end
end
