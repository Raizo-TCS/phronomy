# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  # Raised when a synchronous API would block the EventLoop control thread.
  class EventLoopReentrancyError < Error; end
end
