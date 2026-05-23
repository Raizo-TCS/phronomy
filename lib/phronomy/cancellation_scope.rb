# frozen_string_literal: true

module Phronomy
  # Represents a bounded execution scope that owns a {CancellationToken} and
  # optionally a {Deadline}.
  #
  # +CancellationScope+ replaces ad-hoc +Timeout.timeout+ calls in agent and
  # tool code.  All work performed within a scope should observe the scope's
  # token; when the scope is cancelled (explicitly or by deadline expiry) the
  # token is cancelled and all child tasks that check it will stop.
  #
  # @example Time-bounded invocation
  #   scope = Phronomy::CancellationScope.new.deadline_in(30)
  #   result = scope.pop_queue(completion_queue) do
  #     raise Phronomy::TimeoutError, "timed out"
  #   end
  #
  # @example Explicit cancellation
  #   scope = Phronomy::CancellationScope.new
  #   Phronomy::Task.spawn(name: "worker") do
  #     scope.token.raise_if_cancelled!
  #     # ... do work ...
  #   end
  #   scope.cancel! if some_condition
  class CancellationScope
    # @return [CancellationToken] the token owned by this scope
    attr_reader :token

    # @return [Deadline, nil] the deadline attached to this scope, if any
    attr_reader :deadline

    # @param parent_token [CancellationToken, nil] when provided, cancellation of
    #   the parent token is propagated to this scope's token via a background Task.
    def initialize(parent_token: nil)
      @token    = Phronomy::CancellationToken.new
      @deadline = nil

      # Propagate parent cancellation to this scope asynchronously.
      if parent_token
        Phronomy::Task.spawn(name: "cancellation-scope-propagator") do
          sleep 0.05 until parent_token.cancelled? || @token.cancelled?
          @token.cancel! if parent_token.cancelled? && !@token.cancelled?
        end
      end
    end

    # Attaches a deadline that will cancel this scope after +seconds+.
    #
    # @param seconds [Numeric] timeout duration
    # @return [self]
    def deadline_in(seconds)
      @deadline = Phronomy::Deadline.in(seconds)
      @deadline.attach_to(@token)
      self
    end

    # Cancels this scope immediately.
    # @return [void]
    def cancel!
      @token.cancel!
    end

    # Returns +true+ if this scope has been cancelled.
    # @return [Boolean]
    def cancelled?
      @token.cancelled?
    end

    # Returns the remaining time in seconds before the deadline expires,
    # or +nil+ when no deadline is set.
    # @return [Float, nil]
    def remaining_seconds
      @deadline&.remaining_seconds
    end

    # Pops from +queue+ with a timeout derived from the attached deadline (or
    # +fallback_timeout+ seconds when no deadline is set).  If the pop times out,
    # the scope is cancelled and the block is called (or a {TimeoutError} raised).
    #
    # @param queue [Thread::Queue] the queue to pop from
    # @param fallback_timeout [Numeric, nil] used when no deadline is attached
    # @yield called when the operation times out
    # @raise [Phronomy::TimeoutError] when no block is given and a timeout occurs
    # @return [Object] the popped value
    def pop_queue(queue, fallback_timeout: nil)
      timeout = @deadline&.remaining_seconds || fallback_timeout
      result = if timeout
        queue.pop(timeout: timeout)
      else
        queue.pop
      end

      if result.nil?
        cancel!
        if block_given?
          yield
        else
          raise Phronomy::TimeoutError, "CancellationScope timed out"
        end
      end

      result
    end
  end
end
