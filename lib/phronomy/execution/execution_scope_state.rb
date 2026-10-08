# frozen_string_literal: true

module Phronomy
  # A scope gate shared by observations and framework operations. The same
  # collector lock arbitrates admission and completion; no Execution is held.
  # @api private
  class ExecutionScopeState
    def initialize(collector:, token:)
      @collector = collector
      @token = token
      @error_mutex = Mutex.new
      @error = CancellationError.new("Execution scope is closed")
    end

    def __while_open(&block)
      @collector.while_open(&block)
    end

    def __open?
      @collector.open?
    end

    def __cancellation_token
      @token
    end

    def __cancellation_error
      @error_mutex.synchronize { @error }
    end

    def __set_cancellation_error(error)
      @error_mutex.synchronize { @error = error }
    end
  end
end
