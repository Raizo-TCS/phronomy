# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "SummaryMemory integration", :integration do
  def msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  describe "#save_messages / #load_messages (compression)" do
    let(:memory) { Phronomy::Memory::SummaryMemory.new(max_tokens: 10) }

    let(:messages) do
      [
        msg(:user,      "Tell me about the history of ancient Rome."),
        msg(:assistant, "Ancient Rome was a civilization that grew out of the city-state of Rome."),
        msg(:user,      "Who was Julius Caesar?"),
        msg(:assistant, "Julius Caesar was a Roman general and statesman."),
        msg(:user,      "What happened at the Ides of March?"),
        msg(:assistant, "On March 15, 44 BC, Julius Caesar was assassinated by senators."),
        msg(:user,      "Who succeeded Caesar?"),
        msg(:assistant, "Augustus became the first Roman emperor after the civil wars."),
        msg(:user,      "What is the last topic we discussed?"),
      ]
    end

    before { memory.save_messages(thread_id: "sum-t1", messages: messages) }

    it "prepends a system-role summary message" do
      result = memory.load_messages(thread_id: "sum-t1")
      expect(result.first.role).to eq(:system)
    end

    it "summary content is a non-empty string" do
      result = memory.load_messages(thread_id: "sum-t1")
      expect(result.first.content).to be_a(String)
      expect(result.first.content.strip).not_to be_empty
    end

    it "keeps the most recent 5 messages after the summary" do
      result = memory.load_messages(thread_id: "sum-t1")
      expect(result.length).to eq(6)
    end
  end

  describe "#save_messages / #load_messages (no compression)" do
    let(:memory) { Phronomy::Memory::SummaryMemory.new(max_tokens: 100_000) }

    it "returns messages as-is without calling the LLM" do
      messages = [msg(:user, "Hi"), msg(:assistant, "Hello")]
      memory.save_messages(thread_id: "sum-t2", messages: messages)
      result = memory.load_messages(thread_id: "sum-t2")
      expect(result.length).to eq(2)
      expect(result.first.role).to eq(:user)
    end
  end

  describe "#clear" do
    let(:memory) { Phronomy::Memory::SummaryMemory.new(max_tokens: 10) }

    it "removes both summary and stored messages" do
      messages = Array.new(9) { |i| msg(i.odd? ? :assistant : :user, "message #{i}" * 10) }
      memory.save_messages(thread_id: "sum-t3", messages: messages)
      memory.clear(thread_id: "sum-t3")
      result = memory.load_messages(thread_id: "sum-t3")
      expect(result).to be_empty
    end
  end
end
