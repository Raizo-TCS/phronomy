# frozen_string_literal: true

require_relative "cancellation_error"

module Phronomy
  class ExecutionCancellationError < CancellationError
    attr_reader :outcomes

    def initialize(message = "Execution cancelled", outcomes:, code: nil)
      @outcomes = outcomes
      super(message, code: code)
    end
  end
end
