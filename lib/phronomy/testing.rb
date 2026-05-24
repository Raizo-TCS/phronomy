# frozen_string_literal: true

module Phronomy
  # Test helpers for deterministic, timer-independent testing.
  #
  # @example
  #   require "phronomy/testing"
  #   clock = Phronomy::Testing::FakeClock.new
  #   scheduler = Phronomy::Testing::FakeScheduler.new
  module Testing
  end
end
