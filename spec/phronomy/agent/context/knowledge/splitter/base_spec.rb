# frozen_string_literal: true

RSpec.describe Phronomy::Agent::Context::Knowledge::Splitter::Base do
  describe "#split" do
    it "raises NotImplementedError" do
      expect { described_class.new.split("text") }.to raise_error(NotImplementedError)
    end
  end

  describe "#split_all" do
    it "raises NotImplementedError for each document (delegates to #split)" do
      base = described_class.new
      expect { base.split_all(["a", "b"]) }.to raise_error(NotImplementedError)
    end
  end

  describe "#normalise (private helper)" do
    let(:base) { described_class.new }

    it "accepts a Hash with :text and :metadata" do
      result = base.send(:normalise, {text: "hello", metadata: {source: "x"}})
      expect(result[:text]).to eq("hello")
      expect(result[:metadata]).to eq({source: "x"})
    end

    it "accepts a plain String with empty metadata" do
      result = base.send(:normalise, "hello world")
      expect(result[:text]).to eq("hello world")
      expect(result[:metadata]).to eq({})
    end

    it "raises ArgumentError for unsupported types" do
      expect { base.send(:normalise, 42) }.to raise_error(ArgumentError, /Hash or String/)
    end
  end
end
