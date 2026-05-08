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
  end
end
