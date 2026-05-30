# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Context::Conversation::TrimContext do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  def make_elements(pairs)
    pairs.each_with_index.map do |(role, content), idx|
      tokens = Phronomy::LlmContextWindow::TokenEstimator.estimate(content)
      {seq: idx, message: make_msg(role, content), tokens: tokens, role: role}
    end
  end

  let(:elements) do
    make_elements([
      [:user, "Hello there"],
      [:assistant, "Hi! How can I help?"],
      [:user, "What is Ruby?"],
      [:assistant, "Ruby is a programming language."]
    ])
  end

  let(:budget) do
    Phronomy::LlmContextWindow::TokenBudget.new(context_window: 4096, max_output_tokens: 512)
  end

  subject(:ctx) { described_class.new(message_elements: elements, budget: budget) }

  describe "#initialize" do
    it "exposes budget" do
      expect(ctx.budget).to eq(budget)
    end

    it "calculates total_tokens as sum of element tokens" do
      expected = elements.sum { |e| e[:tokens] }
      expect(ctx.total_tokens).to eq(expected)
    end

    it "returns message_elements as a defensive copy" do
      returned = ctx.message_elements
      expect(returned).to eq(elements)
      expect(returned).not_to be(elements)
    end

    it "does not mutate the original input array when #remove is called" do
      original_size = elements.size
      ctx.remove(0)
      expect(elements.size).to eq(original_size)
    end
  end

  describe "#remove" do
    it "removes elements with matching seq numbers" do
      ctx.remove([0, 2])
      remaining_seqs = ctx.message_elements.map { |e| e[:seq] }
      expect(remaining_seqs).to eq([1, 3])
    end

    it "accepts a single Integer (not wrapped in Array)" do
      ctx.remove(1)
      remaining_seqs = ctx.message_elements.map { |e| e[:seq] }
      expect(remaining_seqs).to eq([0, 2, 3])
    end

    it "recalculates total_tokens after removal" do
      before = ctx.total_tokens
      ctx.remove([0])
      expect(ctx.total_tokens).to be < before
      expect(ctx.total_tokens).to eq(elements.reject { |e| e[:seq] == 0 }.sum { |e| e[:tokens] })
    end

    it "is a no-op when seq does not match any element" do
      before_count = ctx.message_elements.length
      ctx.remove([99])
      expect(ctx.message_elements.length).to eq(before_count)
    end

    it "is chainable (returns self)" do
      expect(ctx.remove([0])).to eq(ctx)
    end
  end

  describe "#messages" do
    it "returns the plain message objects in order" do
      expect(ctx.messages).to eq(elements.map { |e| e[:message] })
    end

    it "reflects removals" do
      ctx.remove([1, 3])
      expect(ctx.messages).to eq([elements[0][:message], elements[2][:message]])
    end
  end

  describe "#message_elements" do
    it "returns a copy that does not share identity with the internal array" do
      a = ctx.message_elements
      b = ctx.message_elements
      expect(a).not_to be(b)
    end

    it "reflects mutations caused by #remove" do
      ctx.remove([0, 1])
      expect(ctx.message_elements.length).to eq(2)
    end
  end

  context "when initialised with nil budget" do
    subject(:ctx) { described_class.new(message_elements: elements, budget: nil) }

    it "exposes nil budget" do
      expect(ctx.budget).to be_nil
    end

    it "still calculates total_tokens" do
      expect(ctx.total_tokens).to be > 0
    end
  end
end
