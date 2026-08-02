# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::VectorSearch do
  let(:embeddings) do
    double("Embeddings").tap do |e|
      allow(e).to receive(:embed) { |text| [text.length.to_f] }
    end
  end

  let(:store) { Phronomy::VectorStore::InMemory.new(dimension: 1) }

  let(:tool_class) do
    described_class.from_store(store, embeddings: embeddings, k: 3)
  end

  describe ".from_store / #execute" do
    it "returns a 'no results' message when the store is empty" do
      result = tool_class.new.call({"query" => "anything"})
      expect(result).to eq("No results found.")
    end

    it "returns formatted results when matches exist" do
      store.add(id: "1", embedding: [5.0], metadata: {content: "hello world"})
      result = tool_class.new.call({"query" => "hello"})
      expect(result).to include("hello world")
    end
  end
end
