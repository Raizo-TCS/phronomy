# frozen_string_literal: true

require_relative "event_loop_reentrancy_error"

module Phronomy
  # Backward-compatible error class name for callers that still rescue the old
  # scheduler-oriented exception. New code should use EventLoopReentrancyError.
  class SchedulerReentrancyError < EventLoopReentrancyError; end
end
