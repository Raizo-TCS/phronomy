# frozen_string_literal: true

require_relative "../execution_contract/cancellation_error"

module Phronomy
  class ExecutionCancellationError < CancellationError
    attr_reader :outcomes

    def initialize(message = "Execution cancelled", outcomes:)
      @outcomes = outcomes
      super(message)
    end
  end
end
