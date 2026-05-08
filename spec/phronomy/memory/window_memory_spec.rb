# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::WindowMemory do
  subject(:memory) { described_class.new(k: 2) }

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:msgs) do
    [
      make_msg(:user, "first"),
      make_msg(:assistant, "reply1"),
      make_msg(:user, "second"),
      make_msg(:assistant, "reply2"),
      make_msg(:user, "third"),
      make_msg(:assistant, "reply3")
    ]
  end

  before { memory.save_messages(thread_id: "t1", messages: msgs) }

  describe "#load_messages" do
    it "returns the last k*2 messages" do
      result = memory.load_messages(thread_id: "t1")
      expect(result.length).to eq(4)
      expect(result).to eq(msgs[-4..])
    end

    it "returns empty array for unknown thread" do
      expect(memory.load_messages(thread_id: "unknown")).to eq([])
    end
  end

  describe "#save_messages" do
    it "replaces stored messages" do
      new_msgs = [make_msg(:user, "new")]
      memory.save_messages(thread_id: "t1", messages: new_msgs)
      expect(memory.load_messages(thread_id: "t1")).to eq(new_msgs)
    end
  end

  describe "#clear" do
    it "removes messages for the thread" do
      memory.clear(thread_id: "t1")
      expect(memory.load_messages(thread_id: "t1")).to eq([])
    end
  end
end
