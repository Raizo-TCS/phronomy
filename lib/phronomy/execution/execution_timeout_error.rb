# frozen_string_literal: true

require_relative "timeout_error"

module Phronomy
  class ExecutionTimeoutError < TimeoutError
    attr_reader :outcomes

    def initialize(message = "Execution timed out", outcomes:, code: nil)
      @outcomes = outcomes
      super(message, code: code)
    end
  end
end
