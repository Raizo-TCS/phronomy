# frozen_string_literal: true

module Phronomy
  # Raised when output token reserve cannot be determined at budget construction
  # time (e.g. no explicit max_output_tokens set and registry value equals the
  # context window).
  class InvalidContextBudgetConfigurationError < Error; end
end
