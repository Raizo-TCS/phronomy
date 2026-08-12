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

  # ---------------------------------------------------------------------------
  # #shutdown (#282 acceptance criteria)
  # ---------------------------------------------------------------------------

  describe "#shutdown" do
    it "shuts down the blocking adapter pool when it was started" do
      runtime = described_class.new
      pool = runtime.blocking_io
      runtime.shutdown
      expect(pool.instance_variable_get(:@shutdown)).to be true
    end

    it "does not raise when called with no tasks and no pool" do
      runtime = described_class.new
      expect { runtime.shutdown }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime.in_event_loop_context? (Issue #312)
  # ---------------------------------------------------------------------------

  describe ".in_event_loop_context?" do
    it "returns false when called outside any task" do
      expect(described_class.in_event_loop_context?).to be(false)
    end
  end
end
