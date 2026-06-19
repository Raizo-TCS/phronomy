# frozen_string_literal: true

module Phronomy
  class Runtime
    # A drop-in replacement for {TimerQueue} that delegates timer scheduling to
    # a {DeterministicScheduler} instead of spawning a dedicated background OS thread.
    #
    # When a {Runtime} is backed by {DeterministicScheduler} (e.g. the +:fiber+
    # runtime backend), {Runtime#timer_queue} returns an instance of this adapter
    # rather than a {TimerQueue}.  This eliminates the +phronomy-timer-queue+
    # background thread for Fiber-based runtimes.
    #
    # Timer callbacks are fired during {DeterministicScheduler#run_until_idle}
    # when {DeterministicScheduler#autorun?} is +true+ (i.e. the +:fiber+ backend).
    # They can also be fired explicitly by calling
    # {DeterministicScheduler#fire_real_timers}.
    #
    # == Known Limitation (Issue #331)
    #
    # Timers that require an actual wall-clock sleep (e.g. a deadline of 10 s
    # from now that will not be reached until real time elapses) will not fire
    # automatically: +run_until_idle+ does not block waiting for future deadlines.
    # This is an accepted limitation of the current stepping-stone implementation.
    # Full resolution requires integrating the cooperative scheduler with the
    # {EventLoop} tick cycle so that a single event-loop iteration checks both
    # ready Fibers and expired wall-clock timers.
    #
    # Use the +:thread+ runtime backend (default) for production workloads that
    # depend on real-time deadline enforcement.
    #
    # @see DeterministicScheduler#schedule_real_after
    # @see DeterministicScheduler#fire_real_timers
    # Bridges wall-clock timers to the cooperative {DeterministicScheduler}.
    #
    # Registers a recurring timer callback with the scheduler's {TimerQueue}
    # so that Fiber-based tasks can await real time without blocking OS threads.
    # @api private
    class SchedulerTimerAdapter
      # @param scheduler [DeterministicScheduler]
      # @api private
      def initialize(scheduler)
        @scheduler = scheduler
      end

      # Schedules a one-shot callback to fire after +seconds+ from now.
      # Delegates to {DeterministicScheduler#schedule_real_after}.
      #
      # Raises {PoolShutdownError} after {#shutdown} has been called, matching
      # the behaviour of {TimerQueue#schedule}.
      #
      # @param seconds [Numeric] delay before the callback fires
      # @yield called when the deadline is reached
      # @return [self]
      # @api private
      def schedule(seconds:, &callback)
        raise Phronomy::PoolShutdownError, "SchedulerTimerAdapter has been shut down" if @stopped

        @scheduler.schedule_real_after(seconds, &callback)
        self
      end

      # No-op: there is no background thread to stop.
      # Present for API compatibility with {TimerQueue}.
      # @return [self]
      # @api private
      def shutdown
        @stopped = true
        self
      end

      # Returns the number of pending (not yet fired) callbacks.
      # @return [Integer]
      # @api private
      def pending_count
        @scheduler.pending_real_timer_count
      end
    end
  end
end
