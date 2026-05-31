# frozen_string_literal: true

RSpec.describe Phronomy::VectorStore::Splitter::FixedSizeSplitter do
  describe ".new" do
    it "raises ArgumentError when chunk_overlap >= chunk_size" do
      expect { described_class.new(chunk_size: 100, chunk_overlap: 100) }.to raise_error(ArgumentError)
      expect { described_class.new(chunk_size: 100, chunk_overlap: 150) }.to raise_error(ArgumentError)
    end

    it "accepts valid chunk_size and chunk_overlap" do
      expect { described_class.new(chunk_size: 200, chunk_overlap: 50) }.not_to raise_error
    end
  end

  describe "#split" do
    subject(:splitter) { described_class.new(chunk_size: 10, chunk_overlap: 2) }

    context "when text is shorter than chunk_size" do
      it "returns a single chunk" do
        result = splitter.split({text: "Hello", metadata: {source: "x"}})
        expect(result.size).to eq(1)
        expect(result.first[:text]).to eq("Hello")
      end
    end

    context "when text is longer than chunk_size" do
      let(:text) { "A" * 25 }

      it "returns multiple chunks" do
        result = splitter.split({text: text, metadata: {}})
        expect(result.size).to be > 1
      end

      it "each chunk is at most chunk_size characters" do
        result = splitter.split({text: text, metadata: {}})
        result.each { |c| expect(c[:text].length).to be <= 10 }
      end

      it "chunks are indexed sequentially in metadata" do
        result = splitter.split({text: text, metadata: {}})
        result.each_with_index { |c, i| expect(c[:metadata][:chunk]).to eq(i) }
      end

      it "overlap text appears at start of subsequent chunks" do
        result = splitter.split({text: "0123456789ABCDE", metadata: {}})
        # chunk 0: "0123456789", chunk 1: "89ABCDE" (2-char overlap)
        expect(result.first[:text]).to eq("0123456789")
        expect(result.last[:text]).to start_with("89")
      end
    end

    context "when document is a plain String" do
      it "accepts String input" do
        result = splitter.split("Hello world")
        expect(result.first[:text]).to eq("Hello worl")
      end
    end

    it "preserves parent metadata and adds :chunk key" do
      result = splitter.split({text: "12345678901", metadata: {source: "file.txt"}})
      result.each { |c| expect(c[:metadata][:source]).to eq("file.txt") }
      expect(result.first[:metadata][:chunk]).to eq(0)
    end
  end

  describe "#split_all" do
    it "splits each document in the array" do
      splitter = described_class.new(chunk_size: 5, chunk_overlap: 1)
      docs = [
        {text: "ABCDEFG", metadata: {idx: 0}},
        {text: "XY", metadata: {idx: 1}}
      ]
      result = splitter.split_all(docs)
      expect(result.size).to be > 2
    end
  end
end
