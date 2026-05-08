# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::Retrieval::Recent do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:msgs) { (1..10).map { |i| make_msg(:user, "msg#{i}") } }

  describe "#select" do
    subject(:retrieval) { described_class.new(k: 3) }

    it "returns the last k*2 messages" do
      result = retrieval.select(msgs)
      expect(result.length).to eq(6)
      expect(result).to eq(msgs.last(6))
    end

    it "returns all messages when fewer than k*2 exist" do
      small = msgs.first(4)
      expect(retrieval.select(small)).to eq(small)
    end

    it "ignores the query argument (recency-based)" do
      expect(retrieval.select(msgs, query: "anything")).to eq(msgs.last(6))
    end

    it "returns empty array for empty input" do
      expect(retrieval.select([])).to eq([])
    end
  end

  describe "default k" do
    subject(:retrieval) { described_class.new }

    it "defaults to k=10 (returns last 20 messages)" do
      long = (1..25).map { |i| make_msg(:user, "m#{i}") }
      expect(retrieval.select(long).length).to eq(20)
    end
  end
end
