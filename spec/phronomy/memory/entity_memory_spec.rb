# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Memory::EntityMemory do
  subject(:memory) { described_class.new(k: 10) }

  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  # -------------------------------------------------------------------------
  # Entity extraction
  # -------------------------------------------------------------------------

  describe "#entities_for" do
    it "returns empty hash before any messages are saved" do
      expect(memory.entities_for("t1")).to eq({})
    end

    it "extracts 'my name is'" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "My name is Alice.")])
      expect(memory.entities_for("t1")[:name]).to eq("Alice")
    end

    it "extracts 'I work at'" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "I work at Acme Corp.")])
      expect(memory.entities_for("t1")[:workplace]).to eq("Acme Corp")
    end

    it "extracts 'I live in'" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "I live in Tokyo.")])
      expect(memory.entities_for("t1")[:location]).to eq("Tokyo")
    end

    it "extracts 'I'm from'" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "I'm from Osaka.")])
      expect(memory.entities_for("t1")[:location]).to eq("Osaka")
    end

    it "extracts 'I like'" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "I like Ruby.")])
      expect(memory.entities_for("t1")[:preference]).to eq("Ruby")
    end

    it "ignores assistant messages for extraction" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:assistant, "My name is Bot.")])
      expect(memory.entities_for("t1")).to eq({})
    end

    it "accumulates entities across multiple save calls" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "My name is Bob.")])
      memory.save_messages(thread_id: "t1", messages: [
        make_msg(:user, "My name is Bob."),
        make_msg(:user, "I live in London.")
      ])
      entities = memory.entities_for("t1")
      expect(entities[:name]).to eq("Bob")
      expect(entities[:location]).to eq("London")
    end

    it "overwrites entity when re-stated" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "My name is Alice.")])
      memory.save_messages(thread_id: "t1", messages: [
        make_msg(:user, "My name is Alice."),
        make_msg(:user, "My name is Bob.")
      ])
      expect(memory.entities_for("t1")[:name]).to eq("Bob")
    end

    it "keeps entities isolated per thread_id" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "My name is Alice.")])
      memory.save_messages(thread_id: "t2", messages: [make_msg(:user, "My name is Charlie.")])
      expect(memory.entities_for("t1")[:name]).to eq("Alice")
      expect(memory.entities_for("t2")[:name]).to eq("Charlie")
    end
  end

  # -------------------------------------------------------------------------
  # load_messages — entity context injection
  # -------------------------------------------------------------------------

  describe "#load_messages" do
    let(:msgs) do
      [
        make_msg(:user, "Hello"),
        make_msg(:assistant, "Hi there!")
      ]
    end

    it "returns messages without entity context when no entities stored" do
      memory.save_messages(thread_id: "t1", messages: msgs)
      result = memory.load_messages(thread_id: "t1")
      expect(result.length).to eq(2)
      expect(result.first.role.to_sym).not_to eq(:system)
    end

    it "injects a system message with known facts when entities exist" do
      memory.save_messages(thread_id: "t1", messages: [
        make_msg(:user, "My name is Alice."),
        *msgs
      ])
      result = memory.load_messages(thread_id: "t1")

      system_msg = result.first
      expect(system_msg.role.to_sym).to eq(:system)
      expect(system_msg.content).to include("Alice")
    end

    it "returns empty array for unknown thread" do
      expect(memory.load_messages(thread_id: "unknown")).to eq([])
    end
  end

  # -------------------------------------------------------------------------
  # clear
  # -------------------------------------------------------------------------

  describe "#clear" do
    it "removes messages and entities for the thread" do
      memory.save_messages(thread_id: "t1", messages: [make_msg(:user, "My name is Alice.")])
      memory.clear(thread_id: "t1")
      expect(memory.entities_for("t1")).to eq({})
      expect(memory.load_messages(thread_id: "t1")).to eq([])
    end
  end
end
