# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::Deadline do
  describe ".in" do
    it "creates a deadline that expires in the future" do
      d = described_class.in(30)
      expect(d.expired?).to be(false)
    end

    it "creates a deadline that is already expired when seconds <= 0" do
      d = described_class.in(0)
      expect(d.expired?).to be(true)
    end
  end

  describe "#remaining_seconds" do
    it "returns approximately the configured duration" do
      d = described_class.in(10)
      expect(d.remaining_seconds).to be_within(1.0).of(10)
    end

    it "returns 0 when already expired" do
      d = described_class.in(-1)
      expect(d.remaining_seconds).to eq(0.0)
    end
  end

  describe "#expired?" do
    it "returns false before expiry" do
      expect(described_class.in(60).expired?).to be(false)
    end

    it "returns true after expiry" do
      d = described_class.in(0.01)
      sleep 0.05
      expect(d.expired?).to be(true)
    end
  end
end
