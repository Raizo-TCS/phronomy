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
  # @example Hard deadline via monotonic clock (recommended)
  #   token = Phronomy::CancellationToken.timeout_after(30)
  #   result = agent.invoke("...", config: { cancellation_token: token })
  #
  # @example Hard deadline via wall-clock (legacy)
  #   token = Phronomy::CancellationToken.new(deadline: Time.now + 30)
  #   result = agent.invoke("...", config: { cancellation_token: token })
  #
  # @example Propagate to parallel workers
  #   token = Phronomy::CancellationToken.new
  #   orchestrator.dispatch_parallel(task1, task2, cancellation_token: token)
  class CancellationToken
    # Returns a new token that will expire after +seconds+ seconds, measured
    # with the monotonic clock (+Process::CLOCK_MONOTONIC+). Unlike constructing
    # a token with +deadline: Time.now + seconds+, this factory is immune to NTP
    # adjustments and DST transitions.
    #
    # @param seconds [Numeric] duration in seconds until the token expires.
    # @return [CancellationToken]
    def self.timeout_after(seconds)
      monotonic_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      new(monotonic_deadline: monotonic_deadline)
    end

    # @param deadline [Time, nil] optional wall-clock deadline; the token reports
    #   +cancelled?+ as +true+ once +Time.now >= deadline+.  Prefer
    #   {.timeout_after} for duration-based cancellation.
    # @param monotonic_deadline [Float, nil] internal monotonic timestamp set by
    #   {.timeout_after}; prefer that factory method over passing this directly.
    def initialize(deadline: nil, monotonic_deadline: nil)
      @cancelled = false
      @deadline = deadline
      @monotonic_deadline = monotonic_deadline
      @mutex = Mutex.new
    end

    # @return [Time, nil] the wall-clock deadline passed to {#initialize}, or +nil+.
    attr_reader :deadline

    # Mark the token as cancelled. Thread-safe; may be called from any thread.
    # @return [self]
    def cancel!
      @mutex.synchronize { @cancelled = true }
      self
    end

    # Returns +true+ when the token has been explicitly cancelled via {#cancel!},
    # when the wall-clock deadline has passed, or when the monotonic deadline
    # (set by {.timeout_after}) has elapsed. Thread-safe.
    # @return [Boolean]
    def cancelled?
      return true if @mutex.synchronize { @cancelled }
      return true if !@deadline.nil? && Time.now >= @deadline
      !@monotonic_deadline.nil? &&
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @monotonic_deadline
    end
  end
end
