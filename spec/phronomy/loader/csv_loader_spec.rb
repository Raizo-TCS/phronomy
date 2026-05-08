# frozen_string_literal: true

require "tempfile"

RSpec.describe Phronomy::Loader::CsvLoader do
  let(:csv_with_headers) do
    <<~CSV
      name,price,category
      Widget,9.99,tools
      Gadget,24.50,electronics
    CSV
  end

  let(:csv_without_headers) do
    <<~CSV
      Alice,30,engineer
      Bob,25,designer
    CSV
  end

  def make_tmp_csv(content)
    file = Tempfile.new(["data", ".csv"])
    file.write(content)
    file.flush
    file
  end

  describe "#load with headers: true (default)" do
    subject(:loader) { described_class.new }

    let(:tmp_file) { make_tmp_csv(csv_with_headers) }
    after { tmp_file.close && tmp_file.unlink }

    it "returns one document per data row" do
      result = loader.load(tmp_file.path)
      expect(result.size).to eq(2)
    end

    it "text is a key: value serialisation of the row" do
      result = loader.load(tmp_file.path)
      expect(result.first[:text]).to include("name: Widget")
      expect(result.first[:text]).to include("price: 9.99")
    end

    it "metadata includes :row (1-based), :source, and column keys" do
      result = loader.load(tmp_file.path)
      first = result.first[:metadata]
      expect(first[:row]).to eq(1)
      expect(first[:source]).to eq(tmp_file.path)
      expect(first[:name]).to eq("Widget")
    end
  end

  describe "#load with text_column: option" do
    let(:tmp_file) { make_tmp_csv(csv_with_headers) }
    after { tmp_file.close && tmp_file.unlink }

    it "uses only the specified column for :text" do
      loader = described_class.new(text_column: "name")
      result = loader.load(tmp_file.path)
      expect(result.first[:text]).to eq("Widget")
      expect(result.last[:text]).to eq("Gadget")
    end
  end

  describe "#load with headers: false" do
    let(:tmp_file) { make_tmp_csv(csv_without_headers) }
    after { tmp_file.close && tmp_file.unlink }

    it "returns one document per row" do
      loader = described_class.new(headers: false)
      result = loader.load(tmp_file.path)
      expect(result.size).to eq(2)
    end

    it "text is a comma-joined row" do
      loader = described_class.new(headers: false)
      result = loader.load(tmp_file.path)
      expect(result.first[:text]).to eq("Alice, 30, engineer")
    end
  end

  describe "#load when file does not exist" do
    it "raises Errno::ENOENT" do
      expect { described_class.new.load("/no/such/file.csv") }.to raise_error(Errno::ENOENT)
    end
  end
end
