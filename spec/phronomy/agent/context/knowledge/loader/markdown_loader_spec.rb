# frozen_string_literal: true

require "tempfile"

RSpec.describe Phronomy::Agent::Context::Knowledge::Loader::MarkdownLoader do
  let(:md_content) do
    <<~MD
      # Introduction
      This is the intro section.

      ## Background
      Some background text.

      ### Details
      More detail here.
    MD
  end

  let(:tmp_file) do
    file = Tempfile.new(["markdown", ".md"])
    file.write(md_content)
    file.flush
    file
  end

  after { tmp_file.close && tmp_file.unlink }

  describe "#load with split_on_headings: true (default)" do
    subject(:loader) { described_class.new }

    it "returns multiple documents (one per heading section)" do
      result = loader.load(tmp_file.path)
      expect(result.size).to be >= 3
    end

    it "each document has a :text key" do
      result = loader.load(tmp_file.path)
      result.each { |doc| expect(doc[:text]).to be_a(String) }
    end

    it "each document with a heading has :section in metadata" do
      result = loader.load(tmp_file.path)
      sections = result.map { |d| d[:metadata][:section] }.compact
      expect(sections).to include("Introduction", "Background", "Details")
    end

    it "each document has :source in metadata" do
      result = loader.load(tmp_file.path)
      result.each { |doc| expect(doc[:metadata][:source]).to eq(tmp_file.path) }
    end
  end

  describe "#load with split_on_headings: false" do
    subject(:loader) { described_class.new(split_on_headings: false) }

    it "returns a single document" do
      result = loader.load(tmp_file.path)
      expect(result.size).to eq(1)
    end

    it "document text equals the full file contents" do
      result = loader.load(tmp_file.path)
      expect(result.first[:text]).to eq(md_content)
    end

    it "document has no :section in metadata" do
      result = loader.load(tmp_file.path)
      expect(result.first[:metadata]).not_to have_key(:section)
    end
  end

  describe "#load with a file that has no headings" do
    let(:no_heading_file) do
      file = Tempfile.new(["noheading", ".md"])
      file.write("Just plain text\nno headings here.")
      file.flush
      file
    end

    after { no_heading_file.close && no_heading_file.unlink }

    it "returns a single document (fallback)" do
      result = described_class.new.load(no_heading_file.path)
      expect(result.size).to eq(1)
    end
  end

  describe "#load when file does not exist" do
    it "raises Errno::ENOENT" do
      expect { described_class.new.load("/no/such/file.md") }.to raise_error(Errno::ENOENT)
    end
  end
end
