# frozen_string_literal: true

# Contract tests for Phronomy::Agent::Context::Knowledge::Embeddings::Base implementations (Issue #212).
#
# Usage:
#   it_behaves_like "an embeddings adapter" do
#     let(:adapter) { described_class.new }
#     let(:stub_vector) { [0.1, 0.2, 0.3] }
#   end
#
# Callers must provide:
#   - `adapter`     — a fresh embeddings adapter instance
#   - `stub_vector` — an Array<Float> that the adapter will return for any embed call
RSpec.shared_examples "an embeddings adapter" do
  describe "interface" do
    it "responds to #embed" do
      expect(adapter).to respond_to(:embed)
    end
  end

  describe "#embed" do
    it "returns an Array" do
      result = adapter.embed("test text")
      expect(result).to be_an(Array)
    end

    it "returns an Array of Float values" do
      result = adapter.embed("test text")
      expect(result).to all(be_a(Float))
    end

    it "returns a non-empty vector" do
      result = adapter.embed("test text")
      expect(result).not_to be_empty
    end

    it "returns a consistent-length vector for the same input" do
      v1 = adapter.embed("hello")
      v2 = adapter.embed("hello")
      expect(v1.length).to eq(v2.length)
    end
  end
end
