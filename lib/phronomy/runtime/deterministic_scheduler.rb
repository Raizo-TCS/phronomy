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
        run_until_idle if @autorun
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
      # Does not fire pending timers — call {#advance} separately to move the
      # virtual clock and enqueue due timer callbacks.
      #
      # @return [self]
      # @api private
      def run_until_idle
        tick until idle?
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
      #
      # @param callable [#call]
      # @return [self]
      # @api private
      def enqueue_fiber(callable)
        @mutex.synchronize { @ready << callable }
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

      private

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
