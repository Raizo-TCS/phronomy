# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::CompositeMemory do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  let(:window_msgs) { [make_msg(:user, "recent1"), make_msg(:assistant, "recent2")] }
  let(:semantic_msgs) { [make_msg(:user, "semantic1")] }

  let(:window_memory) do
    instance_double(Phronomy::Memory::WindowMemory,
      load_messages: window_msgs,
      save_messages: nil,
      clear: nil)
  end

  let(:semantic_memory) do
    instance_double(Phronomy::Memory::SemanticMemory,
      load_messages: semantic_msgs,
      save_messages: nil,
      clear: nil)
  end

  subject(:composite) do
    described_class.new(sources: [
      {memory: window_memory, weight: 0.6},
      {memory: semantic_memory, weight: 0.4}
    ])
  end

  describe "#load_messages" do
    it "merges messages from all sources without duplicates" do
      result = composite.load_messages(thread_id: "t1")
      contents = result.map(&:content)
      expect(contents).to include("recent1", "recent2", "semantic1")
      expect(contents.uniq).to eq(contents)
    end

    it "excludes exact duplicate messages (same role + content)" do
      dup_msg = make_msg(:user, "recent1")
      allow(semantic_memory).to receive(:load_messages).and_return([dup_msg])
      result = composite.load_messages(thread_id: "t1")
      expect(result.count { |m| m.content == "recent1" }).to eq(1)
    end

    it "places system messages before others" do
      sys_msg = make_msg(:system, "You are helpful.")
      user_msg = make_msg(:user, "hi")
      allow(window_memory).to receive(:load_messages).and_return([user_msg, sys_msg])
      allow(semantic_memory).to receive(:load_messages).and_return([])
      result = composite.load_messages(thread_id: "t1")
      expect(result.first.role).to eq(:system)
    end

    context "with token_budget" do
      let(:budget) do
        Phronomy::Context::TokenBudget.new(context_window: 1000, max_output_tokens: 0)
      end

      it "passes a proportional sub-budget to each source" do
        composite.load_messages(thread_id: "t1", token_budget: budget)

        # window_memory gets 60% of 1000 = 600 tokens
        expect(window_memory).to have_received(:load_messages) do |**kwargs|
          expect(kwargs[:token_budget].effective_input_limit).to be_within(1).of(600)
        end

        # semantic_memory gets 40% = 400 tokens
        expect(semantic_memory).to have_received(:load_messages) do |**kwargs|
          expect(kwargs[:token_budget].effective_input_limit).to be_within(1).of(400)
        end
      end
    end
  end

  describe "#save_messages" do
    it "delegates save to all sources" do
      msgs = [make_msg(:user, "hi")]
      composite.save_messages(thread_id: "t1", messages: msgs)
      expect(window_memory).to have_received(:save_messages).with(thread_id: "t1", messages: msgs)
      expect(semantic_memory).to have_received(:save_messages).with(thread_id: "t1", messages: msgs)
    end
  end

  describe "#clear" do
    it "delegates clear to all sources" do
      composite.clear(thread_id: "t1")
      expect(window_memory).to have_received(:clear).with(thread_id: "t1")
      expect(semantic_memory).to have_received(:clear).with(thread_id: "t1")
    end
  end
end
