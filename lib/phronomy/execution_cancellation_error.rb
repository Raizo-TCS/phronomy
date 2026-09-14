# frozen_string_literal: true

module Phronomy
  class ExecutionCancellationError < CancellationError
    attr_reader :outcomes

    def initialize(message = "Execution cancelled", outcomes:)
      @outcomes = outcomes
      super(message)
    end
  end
end
