# frozen_string_literal: true

RSpec.describe Phronomy::RAG::Loader::Base do
  describe "#load" do
    it "raises NotImplementedError" do
      expect { described_class.new.load("anything") }.to raise_error(NotImplementedError)
    end
  end
end
