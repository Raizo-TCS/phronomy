# frozen_string_literal: true

module Phronomy
  class Runtime
    # Tick-based deterministic cooperative scheduler for testing.
    #
    # Unlike {FakeScheduler} (which runs every task synchronously to completion
    # before +spawn+ returns), +DeterministicScheduler+ pushes each task to a
    # ready queue and only advances execution one step at a time via {#tick}.
    # This makes it possible to test:
    #
    # - Task interleaving (two tasks yielding control back and forth)
    # - Virtual-time timer firing order
    # - +await+ suspension and resumption
    # - Cancellation while a task is suspended
    #
    # @example Basic usage
    #   sched = Phronomy::Runtime::DeterministicScheduler.new
    #   rt    = Phronomy::Runtime.new(scheduler: sched)
    #
    #   rt.spawn { Fiber.yield; :done }   # not started yet
    #   sched.tick                        # runs until first Fiber.yield
    #   sched.tick                        # runs to completion
    #   sched.run_until_idle              # same as calling tick until empty
    #
    # @example Virtual clock
    #   sched.schedule_after(1.0) { puts "fired at T=1" }
    #   sched.advance(1.0)    # moves virtual clock forward, fires the timer
    #   sched.run_until_idle  # dispatches the timer callback
    # EXPERIMENTAL Fiber-based cooperative scheduler.
    #
    # Uses {Task::FiberBackend} to run tasks cooperatively without OS threads.
    # Intended for deterministic testing and, in future, as a production
    # cooperative scheduler. Not recommended for production use.
    #
    # Activated via +runtime_backend: :fiber+ in {Phronomy.configure}.
    # @api private
    class DeterministicScheduler < Scheduler
      # Scheduler-aware signal for cooperative suspension.
      #
      # Used by {ConcurrencyGate} and {TaskGroup} to suspend a Fiber until a
      # slot or condition becomes available, without blocking the OS thread.
      # All methods must be called from within a {DeterministicScheduler} tick.
      # @api private
      class CoopSignal
        def initialize(scheduler)
          @scheduler = scheduler
          @waiters = []  # Array of Fiber
        end

        # Suspends the current Fiber until {#notify_one} or {#notify_all} fires.
        # @api private
        # @return [void]
        def wait
          @waiters << Fiber.current
          # Yield with :cooperative_suspend so step_callable knows not to
          # automatically re-enqueue this Fiber — only an explicit notify call
          # should resume it.
          Fiber.yield(:cooperative_suspend)
        end

        # Wakes up one waiting Fiber.
        # @api private
        # @return [void]
        def notify_one
          waiter = @waiters.shift
          @scheduler.enqueue_fiber(-> { waiter.resume }) if waiter
        end

        # Wakes up all waiting Fibers.
        # @api private
        # @return [void]
        def notify_all
          waiters, @waiters = @waiters, []
          waiters.each { |w| @scheduler.enqueue_fiber(-> { w.resume }) }
        end
      end

      # @return [Float] current virtual clock time (seconds since scheduler creation)
      attr_reader :virtual_time

      # @param autorun [Boolean] when +true+, each call to {#spawn} automatically
      #   drains the ready queue via {#run_until_idle} before returning the task.
      #   This makes +DeterministicScheduler+ behave like {FakeScheduler} (tasks
      #   complete synchronously) while still executing them on real Fibers.
      #   Used internally by the +:fiber+ runtime backend.
      # @api private
      def initialize(autorun: false)
        @autorun = autorun
        @ready = []  # Array of callables ({ fiber.resume } or timer callbacks)
        @mutex = Mutex.new
        @virtual_time = 0.0
        @timer_heap = []  # Array of { fire_at:, callback: }
        @real_timer_heap = []  # Array of [fire_at_monotonic, callback] for wall-clock timers
        @clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        # Tracks Fibers suspended in BlockingAdapterPool#await so that
        # run_until_idle knows to keep looping until worker threads complete.
        # Protected by @await_mutex (separate from @mutex to avoid contention).
        @pending_awaits = 0
        @await_mutex = Mutex.new
        @await_cond = ConditionVariable.new
      end

      # Returns +true+ when this scheduler is in autorun mode.
      # @return [Boolean]
      # @api private
      def autorun?
        @autorun
      end

      # Spawns a new {Task} backed by {Task::FiberBackend} and enqueues it.
      # The task does NOT start executing until {#tick} is called.
      #
      # @param name   [String, nil]
      # @param parent [Task, nil]
      # @return [Task]
      # @api private
      def spawn(name:, parent:, &block)
        task = Task.spawn(name: name, parent: parent, backend_class: Task::FiberBackend, &block)
        backend = task.backend
        # Build a self-rescheduling step: after each step, re-enqueue if the
        # Fiber yielded cooperatively and is still alive.
        step_callable = nil
        step_callable = lambda do
          backend.step
          enqueue_fiber(step_callable) if backend.alive? && !backend.cooperative_suspend?
        end
        enqueue_fiber(step_callable)
        # Auto-run only when called from outside a running scheduler tick.
        # When SCHEDULER_KEY is set, the calling code is already inside a managed
        # Fiber; the outer run_until_idle loop will pick up the new task on the
        # next iteration without a recursive re-entry.
        run_until_idle if @autorun && Thread.current.thread_variable_get(SCHEDULER_KEY).nil?
        task
      end

      # Creates a new cooperative signal backed by {CoopSignal}.
      # @return [CoopSignal]
      # @api private
      def new_signal
        CoopSignal.new(self)
      end

      # Suspends the current Fiber until +signal+ is notified.
      # @param signal [CoopSignal]
      # @return [void]
      # @api private
      def wait_for_signal(signal)
        signal.wait
      end

      # Wakes up one Fiber waiting on +signal+.
      # @param signal [CoopSignal]
      # @return [void]
      # @api private
      def raise_signal(signal)
        signal.notify_one
      end

      # Wakes up all Fibers waiting on +signal+.
      # @param signal [CoopSignal]
      # @return [void]
      # @api private
      def raise_signal_all(signal)
        signal.notify_all
      end

      # Executes one ready entry (a fiber step or a timer callback).
      # Sets the thread-local scheduler reference so that +FiberBackend#await+
      # can suspend cooperatively.
      #
      # @return [self]
      # @api private
      def tick
        callable = @mutex.synchronize { @ready.shift }
        return self unless callable

        # Use thread_variable_set (not Thread#[]) so the value is accessible from
        # any Fiber running on this OS thread, not just the current Fiber.
        prev = Thread.current.thread_variable_get(SCHEDULER_KEY)
        Thread.current.thread_variable_set(SCHEDULER_KEY, self)
        callable.call
      ensure
        Thread.current.thread_variable_set(SCHEDULER_KEY, prev)
      end

      # Drains the ready queue by calling {#tick} until it is empty.
      #
      # In autorun mode ({#autorun?} is +true+), also handles wall-clock timers
      # and cooperative blocking-I/O awaits:
      # - Fires any timers whose deadline has already passed on each iteration.
      # - When all ready tasks are done but future timers remain pending, sleeps
      #   until the next deadline and fires them.
      # - When Fibers are suspended in {BlockingAdapterPool::PendingOperation#await}
      #   (tracked via {#track_blocking_await}), waits on a condition variable
      #   that is broadcast by {#enqueue_fiber} when the worker thread completes
      #   (Issue #338).  This ensures run_until_idle does not exit while blocking
      #   I/O operations are still in flight.
      #
      # Does not fire pending virtual timers — call {#advance} for those.
      #
      # @return [self]
      # @api private
      def run_until_idle
        if @autorun
          loop do
            fire_real_timers
            tick until idle?

            # Atomically check all exit conditions.
            should_break = @await_mutex.synchronize do
              idle? && pending_real_timer_count.zero? && @pending_awaits.zero?
            end
            break if should_break

            if idle?
              if pending_real_timer_count > 0 &&
                  @await_mutex.synchronize { @pending_awaits.zero? }
                # Only real timers pending — sleep until the next deadline.
                sleep_until_next_real_timer
              else
                # Pending blocking awaits (pool workers still running).
                # Wait for the completion signal broadcast by enqueue_fiber /
                # complete_blocking_await (30-second safety cap).
                @await_mutex.synchronize { @await_cond.wait(@await_mutex, 30) }
              end
            end
          end
        else
          tick until idle?
        end
        self
      end

      # Advances the virtual clock by +seconds+ and enqueues any timer
      # callbacks that are now due.
      #
      # @param seconds [Numeric]
      # @return [self]
      # @api private
      def advance(seconds)
        @virtual_time += seconds
        fire_due_timers
        self
      end

      # Schedules +callback+ to fire at the given absolute virtual time.
      #
      # @param absolute_time [Float]
      # @yield callback to invoke when the virtual clock reaches +absolute_time+
      # @return [self]
      # @api private
      def schedule_at(absolute_time, &callback)
        @mutex.synchronize do
          @timer_heap << {fire_at: absolute_time, callback: callback}
          @timer_heap.sort_by! { |e| e[:fire_at] }
        end
        self
      end

      # Schedules +callback+ to fire +delay+ seconds from now (virtual time).
      #
      # @param delay [Numeric]
      # @yield callback
      # @return [self]
      # @api private
      def schedule_after(delay, &callback)
        schedule_at(@virtual_time + delay, &callback)
      end

      # Enqueues a callable (Fiber step or arbitrary block) onto the ready queue.
      # Called by {Task::FiberBackend#await} to resume a waiting Fiber.
      # Also wakes any thread blocked in {#run_until_idle} waiting for external
      # completion signals (e.g. from {BlockingAdapterPool} worker threads).
      #
      # @param callable [#call]
      # @return [self]
      # @api private
      def enqueue_fiber(callable)
        @mutex.synchronize { @ready << callable }
        # Broadcast to wake run_until_idle if it is sleeping on @await_cond.
        # @await_mutex is always acquired AFTER releasing @mutex (never nested)
        # to guarantee consistent lock ordering and avoid deadlocks.
        @await_mutex.synchronize { @await_cond.broadcast }
        self
      end

      # Returns +true+ when there are no ready entries to dispatch.
      # @return [Boolean]
      # @api private
      def idle?
        @mutex.synchronize { @ready.empty? }
      end

      # Returns the number of entries currently in the ready queue.
      # @return [Integer]
      # @api private
      def ready_count
        @mutex.synchronize { @ready.size }
      end

      # Returns a list of pending timer entries (not yet fired).
      # Each entry has +:fire_at+ and +:description+ (if set) keys.
      # @return [Array<Hash>]
      # @api private
      def pending_timers
        @mutex.synchronize { @timer_heap.dup }
      end

      # Schedules +callback+ to fire +seconds+ from now (wall-clock time).
      #
      # Unlike {#schedule_after} (which uses virtual time), this method uses
      # the real monotonic clock.  Callbacks are fired during {#run_until_idle}
      # when {#autorun?} is +true+, or explicitly via {#fire_real_timers}.
      #
      # This is the integration point for {TimerQueue} replacement: when a
      # {Runtime} is backed by a +DeterministicScheduler+, its {Runtime#timer_queue}
      # returns a {SchedulerTimerAdapter} that delegates here instead of spawning
      # a background OS thread.
      #
      # @param seconds [Numeric] delay before the callback fires
      # @yield called when the deadline is reached
      # @return [self]
      # @api private
      def schedule_real_after(seconds, &callback)
        fire_at = @clock.call + seconds.to_f
        @mutex.synchronize do
          @real_timer_heap << [fire_at, callback]
          @real_timer_heap.sort_by! { |(t, _)| t }
        end
        self
      end

      # Fires all wall-clock timer callbacks whose deadline has passed.
      # Enqueues each fired callback onto the ready queue for scheduler dispatch.
      #
      # @return [self]
      # @api private
      def fire_real_timers
        now = @clock.call
        due = @mutex.synchronize do
          ready, pending = @real_timer_heap.partition { |(t, _)| t <= now }
          @real_timer_heap.replace(pending)
          ready
        end
        due.each { |(_, cb)| enqueue_fiber(cb) }
        self
      end

      # Returns the number of pending wall-clock timer entries (not yet fired).
      # @return [Integer]
      # @api private
      def pending_real_timer_count
        @mutex.synchronize { @real_timer_heap.size }
      end

      # Registers one pending cooperative blocking-I/O await.
      # Called by {BlockingAdapterPool::PendingOperation#await} before
      # +Fiber.yield+ so that {#run_until_idle} knows not to exit yet.
      # Each call must be balanced by a {#complete_blocking_await} call.
      # @return [self]
      # @api private
      def track_blocking_await
        @await_mutex.synchronize { @pending_awaits += 1 }
        self
      end

      # Marks one pending cooperative blocking-I/O await as complete.
      # Called from the {BlockingAdapterPool::PendingOperation#on_complete}
      # callback (on the pool worker thread) after the result is ready.
      # Decrements the counter and broadcasts to wake {#run_until_idle}.
      # @return [self]
      # @api private
      def complete_blocking_await
        @await_mutex.synchronize do
          @pending_awaits -= 1
          @await_cond.broadcast
        end
        self
      end

      private

      def real_timers_due?
        now = @clock.call
        @mutex.synchronize { @real_timer_heap.any? { |(t, _)| t <= now } }
      end

      # Sleeps until the nearest pending real-timer deadline, then returns.
      # Called only from run_until_idle when the ready queue is empty and at
      # least one future real-timer is pending.  Ensures we never overshoot:
      # sleep is bounded to the exact remaining time to the next deadline.
      # @api private
      def sleep_until_next_real_timer
        next_at = @mutex.synchronize { @real_timer_heap.first&.first }
        return unless next_at

        wait_duration = [next_at - @clock.call, 0.0].max
        sleep(wait_duration) if wait_duration > 0
      end

      def fire_due_timers
        due = @mutex.synchronize do
          ready, pending = @timer_heap.partition { |e| e[:fire_at] <= @virtual_time }
          @timer_heap.replace(pending)
          ready
        end
        due.each { |e| enqueue_fiber(e[:callback]) }
      end
    end
  end
end
