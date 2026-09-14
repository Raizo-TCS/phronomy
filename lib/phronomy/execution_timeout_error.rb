# frozen_string_literal: true

module Phronomy
  class ExecutionTimeoutError < TimeoutError
    attr_reader :outcomes

    def initialize(message = "Execution timed out", outcomes:)
      @outcomes = outcomes
      super(message)
    end
  end
end
