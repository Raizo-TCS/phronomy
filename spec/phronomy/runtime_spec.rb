# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Runtime do
  describe ".instance" do
    it "returns the same object on repeated calls" do
      expect(described_class.instance).to be(described_class.instance)
    end

    it "returns a Runtime" do
      expect(described_class.instance).to be_a(described_class)
    end
  end

  describe ".replace_default_for_test / .restore_default_for_test" do
    it "replaces the shared instance" do
      custom = described_class.new
      previous = described_class.replace_default_for_test(custom)
      expect(described_class.instance).to be(custom)
    ensure
      described_class.restore_default_for_test(previous)
    end
  end

  describe "#shutdown" do
    it "shuts down the offload pool when it was started" do
      runtime = described_class.new
      pool = runtime.offload
      runtime.shutdown
      expect(pool.instance_variable_get(:@shutdown)).to be true
    end

    it "does not raise when called with no tasks and no pool" do
      runtime = described_class.new
      expect { runtime.shutdown }.not_to raise_error
    end
  end

  describe "#offload" do
    it "returns an OffloadPool" do
      runtime = described_class.new
      expect(runtime.offload).to be_a(Phronomy::Concurrency::OffloadPool)
    ensure
      runtime&.shutdown
    end

    it "does not expose the removed #blocking_io API" do
      runtime = described_class.new
      expect(runtime).not_to respond_to(:blocking_io)
    ensure
      runtime&.shutdown
    end
  end

  describe ".in_event_loop_context?" do
    it "returns false when called outside any task" do
      expect(described_class.in_event_loop_context?).to be(false)
    end
  end
end
