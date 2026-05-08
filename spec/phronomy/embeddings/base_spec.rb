# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Embeddings::Base do
  subject(:adapter) { described_class.new }

  describe "#embed" do
    it "raises NotImplementedError" do
      expect { adapter.embed("hello") }.to raise_error(NotImplementedError, /embed/)
    end
  end
end
