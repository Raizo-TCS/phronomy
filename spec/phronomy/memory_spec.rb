# frozen_string_literal: true

require "spec_helper"

# Helper for stubbing messages
def make_message(role, content)
  double("Message", role: role, content: content, tool_calls: nil)
end

RSpec.describe Phronomy::Memory::Base do
  subject(:mem) { described_class.new }

  it "raises NotImplementedError for load_messages" do
    expect { mem.load_messages(thread_id: "t1") }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for save_messages" do
    expect { mem.save_messages(thread_id: "t1", messages: []) }.to raise_error(NotImplementedError)
  end

  it "raises NotImplementedError for clear" do
    expect { mem.clear(thread_id: "t1") }.to raise_error(NotImplementedError)
  end
end

RSpec.describe Phronomy::Memory::WindowMemory do
  subject(:mem) { described_class.new(k: 2) }

  let(:msgs) { (1..6).map { |i| make_message(:user, "msg#{i}") } }

  describe "#save_messages / #load_messages" do
    it "retrieves saved messages as-is (within k*2 limit)" do
      mem.save_messages(thread_id: "t1", messages: msgs[0..2])
      expect(mem.load_messages(thread_id: "t1")).to eq(msgs[0..2])
    end

    it "returns only the most recent k*2 messages when the limit is exceeded" do
      mem.save_messages(thread_id: "t1", messages: msgs)
      result = mem.load_messages(thread_id: "t1")
      expect(result.length).to eq(4)
      expect(result).to eq(msgs[2..])
    end

    it "returns an empty array for an unknown thread_id" do
      expect(mem.load_messages(thread_id: "unknown")).to eq([])
    end
  end

  describe "#clear" do
    it "removes the history for the specified thread" do
      mem.save_messages(thread_id: "t1", messages: msgs[0..1])
      mem.clear(thread_id: "t1")
      expect(mem.load_messages(thread_id: "t1")).to eq([])
    end

    it "does not affect other threads" do
      mem.save_messages(thread_id: "t1", messages: msgs[0..0])
      mem.save_messages(thread_id: "t2", messages: msgs[1..1])
      mem.clear(thread_id: "t1")
      expect(mem.load_messages(thread_id: "t2")).to eq([msgs[1]])
    end
  end

  describe "default k=10" do
    it "retains k*2=20 messages with the default k=10" do
      default_mem = described_class.new
      msgs_20 = (1..25).map { |i| make_message(:user, "m#{i}") }
      default_mem.save_messages(thread_id: "t", messages: msgs_20)
      expect(default_mem.load_messages(thread_id: "t").length).to eq(20)
    end
  end
end

RSpec.describe Phronomy::Memory::SummaryMemory do
  subject(:mem) { described_class.new(max_tokens: 10, summarizer_model: "test-model") }

  # 1 char ≈ 0.25 tokens, so 40 chars ≈ 10 tokens
  let(:short_msgs) { [make_message(:user, "hi"), make_message(:assistant, "hello")] }
  # Messages long enough to exceed the token limit
  let(:long_msgs) do
    (1..8).map { |i| make_message(:user, "message number #{i} with some content here") }
  end

  describe "#save_messages / #load_messages (without compression)" do
    it "saves and returns messages as-is when under the token limit" do
      mem.save_messages(thread_id: "t1", messages: short_msgs)
      result = mem.load_messages(thread_id: "t1")
      expect(result).to eq(short_msgs)
    end
  end

  describe "#save_messages (with compression)" do
    let(:fake_summary_msg) { double("Message", content: "Summary text") }
    let(:fake_chat) do
      dbl = double("Chat")
      allow(dbl).to receive(:with_model).and_return(dbl)
      allow(dbl).to receive(:ask).and_return(fake_summary_msg)
      dbl
    end

    before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

    it "generates a summary with RubyLLM when the token limit is exceeded" do
      mem.save_messages(thread_id: "t1", messages: long_msgs)
      expect(RubyLLM).to have_received(:chat)
    end

    it "prepends the summary message after compression" do
      mem.save_messages(thread_id: "t1", messages: long_msgs)
      result = mem.load_messages(thread_id: "t1")
      expect(result.first.role).to eq(:system)
      expect(result.first.content).to include("[Summary]")
    end

    it "keeps the most recent 5 messages without summarizing them" do
      mem.save_messages(thread_id: "t1", messages: long_msgs)
      result = mem.load_messages(thread_id: "t1")
      # 1 summary + 5 recent = 6 items
      expect(result.length).to eq(6)
    end
  end

  describe "#clear" do
    let(:fake_summary_msg) { double("Message", content: "S") }
    let(:fake_chat) do
      dbl = double("Chat")
      allow(dbl).to receive(:with_model).and_return(dbl)
      allow(dbl).to receive(:ask).and_return(fake_summary_msg)
      dbl
    end

    before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

    it "removes both messages and summary" do
      mem.save_messages(thread_id: "t1", messages: long_msgs)
      mem.clear(thread_id: "t1")
      result = mem.load_messages(thread_id: "t1")
      expect(result).to eq([])
    end
  end
end
