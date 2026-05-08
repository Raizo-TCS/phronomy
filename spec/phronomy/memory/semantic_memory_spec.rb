# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::SemanticMemory do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:fake_embed) do
    # Simple hash from content -> deterministic fake vector
    lambda do |text|
      hash = text.bytes.sum
      [hash.to_f / 1000, (255 - hash % 256).to_f / 1000]
    end
  end

  subject(:memory) do
    described_class.new(embedding_model: "text-embedding-test", k: 3)
  end

  before do
    allow(RubyLLM).to receive(:embed) do |text, **|
      double("embedding", vectors: fake_embed.call(text))
    end
  end

  describe "#save_messages and #load_messages without query" do
    let(:msgs) do
      [
        make_msg(:user, "hello world"),
        make_msg(:assistant, "hi there"),
        make_msg(:user, "how are you")
      ]
    end

    before { memory.save_messages(thread_id: "t1", messages: msgs) }

    it "returns recent messages (up to k) when no query given" do
      result = memory.load_messages(thread_id: "t1")
      expect(result.length).to be <= 3
      expect(result).to include(msgs.last)
    end
  end

  describe "#load_messages with query" do
    let(:msgs) do
      [
        make_msg(:user, "hello world"),
        make_msg(:user, "how are you")
      ]
    end

    before { memory.save_messages(thread_id: "t1", messages: msgs) }

    it "performs semantic search and returns relevant messages" do
      result = memory.load_messages(thread_id: "t1", query: "hello world")
      expect(result).not_to be_empty
    end
  end

  describe "#clear" do
    before { memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "hi")]) }

    it "clears messages for the thread" do
      memory.clear(thread_id: "t1")
      result = memory.load_messages(thread_id: "t1")
      expect(result).to be_empty
    end
  end
end
