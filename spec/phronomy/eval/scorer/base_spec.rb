# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Scorer::Base do
  subject(:scorer) { described_class.new }

  describe "#score" do
    it "raises NotImplementedError because Base is abstract" do
      expect {
        scorer.score(actual: "a", expected: "b")
      }.to raise_error(NotImplementedError)
    end

    it "includes the concrete class name in the error message" do
      expect {
        scorer.score(actual: "a", expected: "b")
      }.to raise_error(NotImplementedError, /#{described_class}#score/)
    end

    it "accepts an optional input keyword without altering the error" do
      expect {
        scorer.score(actual: "a", expected: "b", input: "q")
      }.to raise_error(NotImplementedError)
    end
  end
end
