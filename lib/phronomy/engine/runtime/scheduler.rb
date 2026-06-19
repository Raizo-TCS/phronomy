# frozen_string_literal: true

module Phronomy
  class Runtime
    # Abstract base class for Runtime scheduler backends.
    #
    # A scheduler is responsible for turning +Runtime#spawn+ calls into
    # runnable {Task} objects.  Concrete subclasses decide whether tasks
    # execute on threads, Fibers, or some other execution primitive.
    #
    # The interface is intentionally minimal: callers only see {Task}
    # objects and never interact with the scheduler directly.
    class Scheduler
      # Thread-local key under which the active scheduler is stored.
      # Shared with {Task::FiberBackend} (same symbol).
      # @api private
      SCHEDULER_KEY = :phronomy_deterministic_scheduler

      # Returns the scheduler currently dispatching on this OS thread, or +nil+
      # when running outside a cooperative (Fiber-based) scheduler context.
      #
      # Uses +Thread#thread_variable_get+ (not +Thread#[]+) so that the value is
      # visible across all Fibers running on the same OS thread.
      #
      # @return [Scheduler, nil]
      # @api private
      def self.current
        Thread.current.thread_variable_get(SCHEDULER_KEY)
      end

      # Creates a new scheduler-aware signal object for this scheduler.
      # Signalling primitives use this instead of +ConditionVariable+ when a
      # cooperative scheduler is active.
      #
      # Default implementation raises +NotImplementedError+.  Subclasses that
      # support cooperative suspension (e.g. {DeterministicScheduler}) must
      # override this.
      #
      # @return [Object] an opaque signal handle understood by {#wait_for_signal}
      #   and {#raise_signal}
      # @api private
      def new_signal
        raise NotImplementedError, "#{self.class}#new_signal is not implemented"
      end

      # Suspends the current execution unit (Fiber or Thread) until +signal+ is
      # raised via {#raise_signal}.
      #
      # @param signal [Object] signal handle returned by {#new_signal}
      # @return [void]
      # @api private
      def wait_for_signal(signal)
        raise NotImplementedError, "#{self.class}#wait_for_signal is not implemented"
      end

      # Wakes up one waiter suspended on +signal+.
      #
      # @param signal [Object] signal handle returned by {#new_signal}
      # @return [void]
      # @api private
      def raise_signal(signal)
        raise NotImplementedError, "#{self.class}#raise_signal is not implemented"
      end

      # Wakes up all waiters suspended on +signal+.
      #
      # @param signal [Object] signal handle returned by {#new_signal}
      # @return [void]
      # @api private
      def raise_signal_all(signal)
        raise NotImplementedError, "#{self.class}#raise_signal_all is not implemented"
      end

      # Spawns a new task.
      #
      # @param name   [String, nil] optional human-readable label
      # @param parent [Task, nil]   parent task for cancellation propagation
      # @yield block to execute concurrently (or synchronously, depending on
      #   the concrete scheduler)
      # @return [Task]
      # @api private
      def spawn(name:, parent:, &block)
        raise NotImplementedError, "#{self.class}#spawn is not implemented"
      end

      # Cooperative yield point.
      #
      # Default implementation is a no-op.  Thread-based subclasses should
      # override with +Thread.pass+; fiber-based subclasses should switch to the
      # next runnable fiber.
      # @return [void]
      # @api private
      def yield
        # no-op by default; subclasses override
      end
    end
  end
end
