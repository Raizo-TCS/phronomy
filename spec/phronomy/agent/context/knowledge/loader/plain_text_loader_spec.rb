# frozen_string_literal: true

require "tempfile"

RSpec.describe Phronomy::Agent::Context::Knowledge::Loader::PlainTextLoader do
  subject(:loader) { described_class.new }

  describe "#load" do
    context "when the file exists" do
      let(:tmp_file) do
        file = Tempfile.new(["plain", ".txt"])
        file.write("Hello, world!\nLine 2.")
        file.flush
        file
      end

      after { tmp_file.close && tmp_file.unlink }

      it "returns an array with one document" do
        result = loader.load(tmp_file.path)
        expect(result).to be_a(Array)
        expect(result.size).to eq(1)
      end

      it "document has :text key with the file contents" do
        result = loader.load(tmp_file.path)
        expect(result.first[:text]).to eq("Hello, world!\nLine 2.")
      end

      it "document has :metadata with :source set to the file path" do
        result = loader.load(tmp_file.path)
        expect(result.first[:metadata][:source]).to eq(tmp_file.path)
      end
    end

    context "when the file does not exist" do
      it "raises Errno::ENOENT" do
        expect { loader.load("/nonexistent/path/file.txt") }.to raise_error(Errno::ENOENT)
      end
    end
  end
end
