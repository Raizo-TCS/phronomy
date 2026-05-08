# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::SummaryMemory do
  subject(:memory) { described_class.new(max_tokens: 50) }

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  describe "#load_messages" do
    it "returns messages when nothing is stored" do
      expect(memory.load_messages(thread_id: "t1")).to eq([])
    end

    it "returns recent messages without a summary if under threshold" do
      msgs = Array.new(3) { |i| make_msg(:user, "msg#{i}") }
      memory.save_messages(thread_id: "t1", messages: msgs)
      result = memory.load_messages(thread_id: "t1")
      expect(result).to eq(msgs)
    end
  end

  describe "#save_messages" do
    context "when total tokens are within max_tokens" do
      it "stores messages as-is" do
        msgs = [make_msg(:user, "hello")]  # 5 chars ~ 2 tokens
        memory.save_messages(thread_id: "t1", messages: msgs)
        expect(memory.load_messages(thread_id: "t1")).to eq(msgs)
      end
    end

    context "when total tokens exceed max_tokens" do
      let(:mock_response) { double("response", content: "Summary text") }
      let(:mock_chat) { double("chat", ask: mock_response) }

      before do
        allow(RubyLLM).to receive(:chat).and_return(mock_chat)
      end

      it "calls the LLM to produce a summary and retains only recent messages" do
        # 51 tokens > max_tokens 50: use 51*4 = 204 chars
        msgs = Array.new(11) { |i| make_msg(:user, "x" * 20 + i.to_s) } # ~5 tokens each = 55 total
        memory.save_messages(thread_id: "t1", messages: msgs)
        result = memory.load_messages(thread_id: "t1")
        # First element should be the summary system message
        expect(result.first.role).to eq(:system)
        expect(result.first.content).to include("Summary text")
      end
    end
  end

  describe "#clear" do
    it "removes messages and summaries for the thread" do
      msgs = [make_msg(:user, "hi")]
      memory.save_messages(thread_id: "t1", messages: msgs)
      memory.clear(thread_id: "t1")
      expect(memory.load_messages(thread_id: "t1")).to eq([])
    end
  end
end
