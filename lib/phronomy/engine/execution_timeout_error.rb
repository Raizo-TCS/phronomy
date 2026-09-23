# frozen_string_literal: true

require_relative "timeout_error"

module Phronomy
  class ExecutionTimeoutError < TimeoutError
    attr_reader :outcomes

    def initialize(message = "Execution timed out", outcomes:)
      @outcomes = outcomes
      super(message)
    end
  end
end
