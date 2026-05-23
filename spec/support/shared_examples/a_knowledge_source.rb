# frozen_string_literal: true

# Contract tests for Phronomy::KnowledgeSource::Base implementations (Issue #212).
#
# Usage:
#   it_behaves_like "a knowledge source" do
#     let(:source) { described_class.new("some content") }
#     let(:expected_static) { true }   # or false
#   end
#
# Callers must provide:
#   - `source`          — a fresh knowledge source instance, pre-loaded with at
#                         least one document/chunk
#   - `expected_static` — boolean matching the source's static? return value
RSpec.shared_examples "a knowledge source" do
  describe "interface" do
    it "responds to #fetch" do
      expect(source).to respond_to(:fetch)
    end

    it "responds to #static?" do
      expect(source).to respond_to(:static?)
    end
  end

  describe "#static?" do
    it "returns a Boolean" do
      result = source.static?
      expect([true, false]).to include(result)
    end

    it "returns the expected static? value" do
      expect(source.static?).to eq(expected_static)
    end
  end

  describe "#fetch" do
    it "returns an Array" do
      result = source.fetch(query: "test")
      expect(result).to be_an(Array)
    end

    it "each chunk includes :content and :type keys" do
      chunks = source.fetch(query: "test")
      next if chunks.empty? # allow empty results

      chunks.each do |chunk|
        expect(chunk).to include(:content, :type)
      end
    end

    it ":content is a String" do
      chunks = source.fetch(query: "test")
      next if chunks.empty?

      chunks.each { |c| expect(c[:content]).to be_a(String) }
    end

    it ":type is a Symbol" do
      chunks = source.fetch(query: "test")
      next if chunks.empty?

      chunks.each { |c| expect(c[:type]).to be_a(Symbol) }
    end

    it "accepts query: nil without raising" do
      expect { source.fetch(query: nil) }.not_to raise_error
    end
  end
end
