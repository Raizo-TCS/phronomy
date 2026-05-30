# frozen_string_literal: true

require "spec_helper"
require "ostruct"

RSpec.describe Phronomy::KnowledgeSource::StaticKnowledge do
  subject(:ks) { described_class.new("Ruby is a dynamic language.") }

  # Contract tests: verify StaticKnowledge satisfies the knowledge source interface (Issue #212).
  it_behaves_like "a knowledge source" do
    let(:source) { described_class.new("Ruby is a dynamic language.") }
    let(:expected_static) { true }
  end

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

  it "omits :source when not given" do
    expect(ks.fetch.first).not_to have_key(:source)
  end

  it "includes :source when given" do
    ks2 = described_class.new("policy text", source: "policy.md")
    expect(ks2.fetch.first[:source]).to eq("policy.md")
  end
end

RSpec.describe Phronomy::KnowledgeSource::EntityKnowledge do
  # Contract tests: verify EntityKnowledge satisfies the knowledge source interface (Issue #212).
  it_behaves_like "a knowledge source" do
    let(:source) { described_class.new }
    let(:expected_static) { false }
  end

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

RSpec.describe "KnowledgeSource CancellationToken propagation (#242)" do
  let(:cancelled_token) do
    Phronomy::Concurrency::CancellationToken.new.tap(&:cancel!)
  end

  it "StaticKnowledge#fetch raises CancellationError when token is cancelled" do
    ks = Phronomy::KnowledgeSource::StaticKnowledge.new("some text")
    expect { ks.fetch(cancellation_token: cancelled_token) }.to raise_error(Phronomy::CancellationError)
  end

  it "EntityKnowledge#fetch raises CancellationError when token is cancelled" do
    ks = Phronomy::KnowledgeSource::EntityKnowledge.new
    expect { ks.fetch(cancellation_token: cancelled_token) }.to raise_error(Phronomy::CancellationError)
  end

  it "KnowledgeSource::Base#fetch raises CancellationError when token is cancelled" do
    ks = Phronomy::KnowledgeSource::Base.new
    expect { ks.fetch(cancellation_token: cancelled_token) }.to raise_error(Phronomy::CancellationError)
  end
end
