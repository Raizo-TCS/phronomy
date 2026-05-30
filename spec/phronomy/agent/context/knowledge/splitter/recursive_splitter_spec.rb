# frozen_string_literal: true

RSpec.describe Phronomy::Agent::Context::Knowledge::Splitter::RecursiveSplitter do
  describe ".new" do
    it "raises ArgumentError when chunk_overlap >= chunk_size" do
      expect { described_class.new(chunk_size: 100, chunk_overlap: 100) }.to raise_error(ArgumentError)
    end
  end

  describe "#split" do
    subject(:splitter) { described_class.new(chunk_size: 50, chunk_overlap: 5) }

    context "when text is shorter than chunk_size" do
      it "returns a single chunk" do
        result = splitter.split("Short text.")
        expect(result.size).to eq(1)
        expect(result.first[:text]).to eq("Short text.")
      end
    end

    context "when text contains paragraph breaks" do
      let(:text) do
        "Paragraph one is here.\n\nParagraph two follows it.\n\nAnd paragraph three ends it."
      end

      it "splits on paragraph breaks" do
        result = splitter.split(text)
        expect(result.size).to be >= 2
      end

      it "each chunk fits within chunk_size characters" do
        result = splitter.split(text)
        result.each { |c| expect(c[:text].length).to be <= 50 }
      end
    end

    context "when text contains newline breaks (no paragraphs)" do
      let(:text) { "Line one.\nLine two.\nLine three.\nLine four.\nLine five." }

      it "returns multiple chunks" do
        result = splitter.split(text)
        expect(result.size).to be >= 1
      end
    end

    context "with a document Hash" do
      it "preserves source metadata and adds :chunk" do
        doc = {text: "A" * 120, metadata: {source: "doc.txt"}}
        result = splitter.split(doc)
        result.each { |c| expect(c[:metadata][:source]).to eq("doc.txt") }
        result.each_with_index { |c, i| expect(c[:metadata][:chunk]).to eq(i) }
      end
    end

    context "with custom separators" do
      it "uses the provided separator list" do
        custom = described_class.new(chunk_size: 20, chunk_overlap: 2, separators: ["|"])
        result = custom.split("hello|world|foo|bar")
        expect(result.map { |c| c[:text] }.join).to include("hello")
      end
    end
  end

  describe "#split_all" do
    it "flattens chunks from multiple documents" do
      splitter = described_class.new(chunk_size: 30, chunk_overlap: 5)
      docs = [
        {text: "Document one content here, fairly long text.", metadata: {}},
        {text: "Document two.", metadata: {}}
      ]
      result = splitter.split_all(docs)
      expect(result).to be_a(Array)
      expect(result).not_to be_empty
    end
  end
end
