# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Phronomy::Context::CompactionContext do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  def make_elements(pairs)
    pairs.each_with_index.map do |(role, content), idx|
      tokens = Phronomy::Context::TokenEstimator.estimate(content)
      {seq: idx, message: make_msg(role, content), tokens: tokens, role: role}
    end
  end

  let(:elements) do
    make_elements([
      [:user, "Msg 0"],
      [:assistant, "Msg 1"],
      [:user, "Msg 2"],
      [:assistant, "Msg 3"],
      [:user, "Msg 4"]
    ])
  end

  let(:budget) do
    Phronomy::Context::TokenBudget.new(context_window: 4096, max_output_tokens: 512)
  end

  subject(:ctx) { described_class.new(message_elements: elements, budget: budget) }

  describe "#initialize" do
    it "exposes budget" do
      expect(ctx.budget).to eq(budget)
    end

    it "exposes total_tokens" do
      expect(ctx.total_tokens).to eq(elements.sum { |e| e[:tokens] })
    end

    it "result_messages defaults to the plain messages in order" do
      expect(ctx.result_messages).to eq(elements.map { |e| e[:message] })
    end
  end

  describe "#compact with a Range" do
    let(:summary_text) { "Summary of messages 0 and 1" }

    it "replaces the range with a single :system summary message" do
      result = ctx.compact(0..1) { |_| summary_text }
      expect(result.first.role).to eq(:system)
      expect(result.first.content).to eq(summary_text)
    end

    it "appends the remaining messages after the summary" do
      result = ctx.compact(0..1) { |_| summary_text }
      remaining_contents = result[1..].map(&:content)
      expect(remaining_contents).to eq(["Msg 2", "Msg 3", "Msg 4"])
    end

    it "updates result_messages" do
      ctx.compact(0..1) { |_| summary_text }
      expect(ctx.result_messages.first.content).to eq(summary_text)
      expect(ctx.result_messages.length).to eq(4) # 1 summary + 3 remaining
    end

    it "yields the selected elements to the block" do
      yielded = nil
      ctx.compact(0..1) do |els|
        yielded = els
        "summary"
      end
      expect(yielded.map { |e| e[:seq] }).to eq([0, 1])
    end
  end

  describe "#compact with an exclusive Range" do
    it "compacts the correct elements" do
      result = ctx.compact(0...2) { |_| "summary" }
      expect(result.length).to eq(4) # 1 summary + 3 remaining
    end
  end

  describe "#compact with Integer index" do
    it "compacts only the element at that index" do
      result = ctx.compact(0) { |_| "first only summary" }
      expect(result.first.content).to eq("first only summary")
      expect(result.length).to eq(5) # 1 summary + 4 remaining
    end
  end

  describe "#compact — nil / empty range guard" do
    it "returns current result_messages unchanged when range is out of bounds" do
      original = ctx.result_messages.dup
      result = ctx.compact(10..20) do |_|
        "never called"
      end
      expect(result).to eq(original)
    end
  end

  describe "#compact — memory save_compaction" do
    let(:mock_memory) { double("memory") }
    let(:thread_id) { "thread-42" }

    subject(:ctx) do
      described_class.new(
        message_elements: elements,
        budget: budget,
        thread_id: thread_id,
        memory: mock_memory
      )
    end

    context "when memory responds to :save_compaction" do
      before do
        allow(mock_memory).to receive(:respond_to?).with(:save_compaction).and_return(true)
        allow(mock_memory).to receive(:save_compaction)
      end

      it "calls save_compaction with start_seq, end_seq, and summary_text" do
        ctx.compact(1..2) { |_| "mid summary" }

        expect(mock_memory).to have_received(:save_compaction).with(
          thread_id: thread_id,
          start_seq: 1,
          end_seq: 2,
          summary_text: "mid summary"
        )
      end
    end

    context "when memory does not respond to :save_compaction" do
      before do
        allow(mock_memory).to receive(:respond_to?).with(:save_compaction).and_return(false)
      end

      it "does not raise" do
        expect { ctx.compact(0..0) { |_| "summary" } }.not_to raise_error
      end
    end
  end

  describe "two consecutive #compact calls" do
    it "each call updates result_messages independently (last call wins)" do
      ctx.compact(0..1) { |_| "First summary" }
      ctx.compact(0..0) { |_| "Second summary" }
      # After second call, result_messages reflects the second compact
      expect(ctx.result_messages.first.content).to eq("Second summary")
    end
  end

  context "with nil memory and nil thread_id" do
    subject(:ctx) do
      described_class.new(message_elements: elements, budget: budget)
    end

    it "does not raise when memory is nil" do
      expect { ctx.compact(0..1) { |_| "summary" } }.not_to raise_error
    end
  end

  # Regression test for Issue #53: summary message objects produced by #compact
  # must not use OpenStruct, which silently returns nil for any unknown method call.
  describe "summary message value object (Issue #53)" do
    it "raises NoMethodError for unknown attributes (not silently nil)" do
      result = ctx.compact(0..1) { |_| "some summary" }
      summary_msg = result.first
      expect { summary_msg.nonexistent_attribute }.to raise_error(NoMethodError)
    end

    it "has role :system and the provided summary text" do
      result = ctx.compact(0..1) { |_| "generated summary" }
      summary_msg = result.first
      expect(summary_msg.role).to eq(:system)
      expect(summary_msg.content).to eq("generated summary")
    end
  end
end
