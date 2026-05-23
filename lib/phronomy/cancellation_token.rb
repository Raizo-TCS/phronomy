# frozen_string_literal: true

module Phronomy
  # Provides cooperative cancellation for agent invocations.
  #
  # Pass a token to an agent via +config: { cancellation_token: token }+.
  # The agent checks the token before each LLM call and raises
  # {Phronomy::CancellationError} when the token is cancelled or the
  # optional deadline has passed.
  #
  # A token may be shared across multiple agent invocations and across threads;
  # all access to internal state is protected by a Mutex.
  #
  # @example Explicit cancel from another thread
  #   token = Phronomy::CancellationToken.new
  #   Thread.new { sleep 5; token.cancel! }
  #   result = agent.invoke("...", config: { cancellation_token: token })
  #
  # @example Hard deadline (auto-cancel after 30 s)
  #   token = Phronomy::CancellationToken.new(deadline: Time.now + 30)
  #   result = agent.invoke("...", config: { cancellation_token: token })
  #
  # @example Propagate to parallel workers
  #   token = Phronomy::CancellationToken.new
  #   orchestrator.dispatch_parallel(task1, task2, cancellation_token: token)
  class CancellationToken
    # @param deadline [Time, nil] optional hard deadline; the token reports
    #   +cancelled?+ as +true+ once +Time.now >= deadline+.
    def initialize(deadline: nil)
      @cancelled = false
      @deadline = deadline
      @mutex = Mutex.new
    end

    # @return [Time, nil] the deadline passed to {#initialize}, or +nil+.
    attr_reader :deadline

    # Mark the token as cancelled. Thread-safe; may be called from any thread.
    # @return [self]
    def cancel!
      @mutex.synchronize { @cancelled = true }
      self
    end

    # Returns +true+ when the token has been explicitly cancelled via {#cancel!}
    # or when the deadline has passed. Thread-safe.
    # @return [Boolean]
    def cancelled?
      return true if @mutex.synchronize { @cancelled }
      !@deadline.nil? && Time.now >= @deadline
    end
  end
end
