# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::KnowledgeSource::StaticKnowledge do
  subject(:ks) { described_class.new("Ruby is a dynamic language.") }

  it "returns a chunk with :content and :type" do
    chunks = ks.fetch
    expect(chunks.length).to eq(1)
    expect(chunks.first[:content]).to eq("Ruby is a dynamic language.")
    expect(chunks.first[:type]).to eq(:static)
  end

  it "accepts a custom type" do
    ks2 = described_class.new("fact", type: :fact)
    expect(ks2.fetch.first[:type]).to eq(:fact)
  end

  it "ignores the query argument" do
    expect(ks.fetch(query: "anything")).to eq(ks.fetch)
  end
end

RSpec.describe Phronomy::KnowledgeSource::EntityKnowledge do
  def make_msg(role, content)
    OpenStruct.new(role: role, content: content)
  end

  subject(:ks) { described_class.new }

  describe "#update and #fetch" do
    it "returns empty array when no entities found" do
      ks.update(messages: [make_msg(:user, "hello there")])
      expect(ks.fetch).to eq([])
    end

    it "extracts name entity and returns a knowledge chunk" do
      ks.update(messages: [make_msg(:user, "My name is Alice")])
      chunks = ks.fetch
      expect(chunks.length).to eq(1)
      expect(chunks.first[:content]).to include("name: Alice")
      expect(chunks.first[:type]).to eq(:entity)
    end

    it "accumulates entities across multiple update calls" do
      ks.update(messages: [make_msg(:user, "My name is Alice")])
      ks.update(messages: [make_msg(:user, "I live in Tokyo")])
      chunks = ks.fetch
      expect(chunks.first[:content]).to include("name: Alice")
      expect(chunks.first[:content]).to include("location: Tokyo")
    end

    it "only processes user messages" do
      ks.update(messages: [make_msg(:assistant, "My name is Bot")])
      expect(ks.fetch).to eq([])
    end
  end

  describe "#entities" do
    it "exposes the accumulated entity hash" do
      ks.update(messages: [make_msg(:user, "I live in Osaka")])
      expect(ks.entities[:location]).to eq("Osaka")
    end
  end
end
