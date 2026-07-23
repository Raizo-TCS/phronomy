# frozen_string_literal: true

module Phronomy
  module Concurrency
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
    #   token = Phronomy::Concurrency::CancellationToken.new
    #   Thread.new { sleep 5; token.cancel! }
    #   result = agent.invoke("...", config: { cancellation_token: token })
    #
    # @example Hard deadline via monotonic clock (recommended)
    #   token = Phronomy::Concurrency::CancellationToken.timeout_after(30)
    #   result = agent.invoke("...", config: { cancellation_token: token })
    #
    # @example Hard deadline via wall-clock (legacy)
    #   token = Phronomy::Concurrency::CancellationToken.new(deadline: Time.now + 30)
    #   result = agent.invoke("...", config: { cancellation_token: token })
    #
    # @example Propagate to parallel workers
    #   token = Phronomy::Concurrency::CancellationToken.new
    #   orchestrator.dispatch_parallel(task1, task2, cancellation_token: token)
    class CancellationToken
      # Returns a new token that will expire after +seconds+ seconds, measured
      # with the monotonic clock (+Process::CLOCK_MONOTONIC+). Unlike constructing
      # a token with +deadline: Time.now + seconds+, this factory is immune to NTP
      # adjustments and DST transitions.
      #
      # @param seconds [Numeric] duration in seconds until the token expires.
      # @return [CancellationToken]
      # @api public
      def self.timeout_after(seconds)
        monotonic_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        new(monotonic_deadline: monotonic_deadline)
      end

      # @param deadline [Time, nil] optional wall-clock deadline; the token reports
      #   +cancelled?+ as +true+ once +Time.now >= deadline+.  Prefer
      #   {.timeout_after} for duration-based cancellation.
      # @param monotonic_deadline [Float, nil] internal monotonic timestamp set by
      #   {.timeout_after}; prefer that factory method over passing this directly.
      # @api public
      # mutant:disable - removing @cancelled = false is equivalent because nil is falsey
      def initialize(deadline: nil, monotonic_deadline: nil)
        @cancelled = false
        @deadline = deadline
        @monotonic_deadline = monotonic_deadline
        @mutex = Mutex.new
        @cancel_callbacks = []
      end

      # @return [Time, nil] the wall-clock deadline passed to {#initialize}, or +nil+.
      attr_reader :deadline

      # Returns the remaining seconds until the monotonic deadline fires, or +nil+
      # when no monotonic deadline is set.  Returns 0.0 if already past.
      # @return [Float, nil]
      # @api public
      def remaining_monotonic_seconds
        return nil if @monotonic_deadline.nil?
        remaining = @monotonic_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [remaining, 0.0].max
      end

      # Registers a one-shot callback invoked when this token is explicitly
      # cancelled via {#cancel!}.  If the token is already cancelled, the block
      # is called immediately (still within the caller's thread).
      #
      # Callbacks are NOT fired for deadline-based cancellation (i.e. when
      # {#cancelled?} returns +true+ due to +@monotonic_deadline+ expiry).  Use
      # {Phronomy::Concurrency::CancellationScope#deadline_in}, which registers
      # a timer via {Runtime#timer_queue} and calls {#cancel!} on expiry — this
      # fires all +on_cancel+ callbacks automatically.  {.timeout_after} is a
      # lightweight alternative that uses lazy clock comparison only and does
      # NOT trigger callbacks on expiry.
      #
      # @yield called with no arguments when (or if) the token is cancelled
      # @return [self]
      # @api public
      # mutant:disable - mutex removal mutation is GVL-safe equivalent under MRI
      def on_cancel(&block)
        already_cancelled = @mutex.synchronize do
          if @cancelled
            true
          else
            @cancel_callbacks << block
            false
          end
        end
        block.call if already_cancelled
        self
      end

      # Mark the token as cancelled and fire any registered {#on_cancel} callbacks.
      # Thread-safe; idempotent — calling multiple times has no additional effect.
      # @return [self]
      # @api public
      # mutant:disable - mutex removal and dup-vs-ref mutations are GVL-safe equivalents
      def cancel!
        callbacks = @mutex.synchronize do
          return self if @cancelled
          @cancelled = true
          @cancel_callbacks.dup
        end
        callbacks.each(&:call)
        self
      end

      # Returns +true+ when the token has been explicitly cancelled via {#cancel!},
      # when the wall-clock deadline has passed, or when the monotonic deadline
      # (set by {.timeout_after}) has elapsed. Thread-safe.
      # @return [Boolean]
      # @api public
      # mutant:disable - mutex removal on @cancelled read is GVL-safe equivalent under MRI
      def cancelled?
        return true if @mutex.synchronize { @cancelled }
        return true if !@deadline.nil? && Time.now >= @deadline
        !@monotonic_deadline.nil? &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @monotonic_deadline
      end

      # Raises {Phronomy::CancellationError} if the token is cancelled.
      # A convenience method for cooperative cancellation checks inside tools,
      # RAG loaders, and hooks, replacing the +if cancelled? then raise+ pattern.
      #
      # @param message [String] optional error message
      # @return [nil] when the token is not cancelled
      # @raise [Phronomy::CancellationError] when the token is cancelled
      # @api public
      # mutant:disable - raise(CancellationError) resolves to raise(Phronomy::CancellationError) in this namespace
      def raise_if_cancelled!(message = "invocation cancelled")
        raise Phronomy::CancellationError, message if cancelled?
      end
    end
  end
end
