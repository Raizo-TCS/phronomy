# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  # Raised when mandatory context content (system instructions, tool definitions,
  # current input) exhausts the model's context window, leaving no room for
  # prior conversation history.
  class ContextBudgetExceededError < Error; end
end
