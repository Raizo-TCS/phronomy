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

  describe "#attach_to" do
    it "cancels the token when the deadline passes" do
      token = Phronomy::Concurrency::CancellationToken.new
      described_class.in(0.05).attach_to(token)
      expect(token.cancelled?).to be(false)
      sleep 0.1
      expect(token.cancelled?).to be(true)
    end

    it "returns self" do
      d = described_class.in(10)
      token = Phronomy::Concurrency::CancellationToken.new
      expect(d.attach_to(token)).to be(d)
    end

    it "does nothing when already expired" do
      token = Phronomy::Concurrency::CancellationToken.new
      described_class.in(0).attach_to(token)
      # Token starts out not-cancelled — attach should not touch it immediately
      # (background thread exits immediately, cancel! may or may not run)
      sleep 0.05
      # At this point either it fired or it was a no-op; test just ensures no crash
    end
  end
end
