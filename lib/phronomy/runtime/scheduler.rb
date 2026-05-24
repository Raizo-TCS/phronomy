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
      # Spawns a new task.
      #
      # @param name   [String, nil] optional human-readable label
      # @param parent [Task, nil]   parent task for cancellation propagation
      # @yield block to execute concurrently (or synchronously, depending on
      #   the concrete scheduler)
      # @return [Task]
      def spawn(name:, parent:, &block)
        raise NotImplementedError, "#{self.class}#spawn is not implemented"
      end

      # Cooperative yield point.
      #
      # Default implementation is a no-op.  Thread-based subclasses should
      # override with +Thread.pass+; fiber-based subclasses should switch to the
      # next runnable fiber.
      # @return [void]
      def yield
        # no-op by default; subclasses override
      end
    end
  end
end
