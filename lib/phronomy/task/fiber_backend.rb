# frozen_string_literal: true

module Phronomy
  class Task
    # Cooperative task backend using Ruby Fibers.
    #
    # Unlike {ImmediateBackend} (which runs the block to completion on the
    # calling thread) or {ThreadBackend} (which runs the block on a new OS
    # thread), +FiberBackend+ wraps the block in a +Fiber+ that is NOT started
    # immediately.  The owning scheduler calls {#step} to advance execution one
    # cooperative step at a time.
    #
    # This backend is used exclusively by {Runtime::DeterministicScheduler} to
    # enable deterministic, wall-clock-free testing of concurrent logic.
    #
    # Thread-local key under which the currently active {DeterministicScheduler}
    # is stored so that {#await} can suspend cooperatively.
    SCHEDULER_KEY = :phronomy_deterministic_scheduler

    class FiberBackend < Backend
      def initialize(task:, &block)
        super
        @value = nil
        @error = nil
        @cancel_error = nil
        @started = false
        @cooperative_suspend = false

        # Capture `self` (the FiberBackend instance) in the closure so that
        # instance-variable writes from inside the Fiber update this object.
        @fiber = Fiber.new do
          task.transition!(:running)
          begin
            # If cancel! was called before the first step, raise immediately.
            raise @cancel_error if @cancel_error

            @value = block.call
            task.transition!(:completed, value: @value)
          rescue CancellationError => e
            task.transition!(:cancelled, error: e)
            @error = e
          rescue => e
            task.transition!(:failed, error: e)
            @error = e
          ensure
            task.transition!(:cancelled) unless task.done?
          end
        end
      end

      # Advances execution by one scheduler step.
      # Resumes the Fiber until it yields (via +Fiber.yield+) or finishes.
      # @return [self]
      # @api private
      def step
        return self unless @fiber.alive?

        @started = true
        yield_value = @fiber.resume
        # A yield value of :cooperative_suspend signals that the Fiber deliberately
        # suspended itself (e.g. inside CoopSignal#wait) and must NOT be
        # re-enqueued by step_callable — it will be resumed by an explicit signal.
        @cooperative_suspend = (yield_value == :cooperative_suspend)
        self
      end

      # Returns +true+ if the Fiber yielded cooperatively (via a signal wait)
      # and should not be automatically re-enqueued by the scheduler.
      # @return [Boolean]
      # @api private
      def cooperative_suspend?
        @cooperative_suspend
      end

      # Blocks until the task completes.
      #
      # When called from within a {DeterministicScheduler}-managed Fiber,
      # suspends the current Fiber cooperatively and schedules it to resume
      # when this task completes.  When called from outside a managed Fiber
      # (e.g. the main fiber or a regular thread), drives execution by calling
      # {#step} in a loop.
      #
      # @return [Object]
      # @raise [Exception]
      # @api private
      def await
        unless @fiber.alive?
          raise @error if @error
          return @value
        end

        scheduler = Thread.current.thread_variable_get(SCHEDULER_KEY)
        # Fiber.main was added in Ruby 3.2.4+; fall back to true (assume we are
        # inside a managed Fiber whenever a scheduler is active).
        in_managed_fiber = !Fiber.respond_to?(:main) || Fiber.current != Fiber.main
        if scheduler && in_managed_fiber
          # Cooperative context: suspend current Fiber until task is done.
          waiting_fiber = Fiber.current
          @task.on_complete { scheduler.enqueue_fiber(-> { waiting_fiber.resume }) }
          Fiber.yield(:cooperative_suspend)
        else
          # Non-cooperative context: drive the fiber to completion.
          step while @fiber.alive?
        end

        raise @error if @error
        @value
      end

      # @return [Boolean] +true+ while the Fiber has not yet finished
      # @api private
      def alive?
        @fiber.alive?
      end

      # Requests cancellation.
      # If the Fiber is suspended (has already started), delivers
      # +CancellationError+ via +Fiber#raise+.  If it has not yet started,
      # records the error so it is raised on the first {#step}.
      # @return [self]
      # @api private
      def cancel!
        @cancel_error = CancellationError.new("Task cancelled")
        if @fiber.alive? && @started
          begin
            @fiber.raise(CancellationError, "Task cancelled")
          rescue FiberError
            # Fiber may have completed between the alive? check and raise — safe to ignore.
          end
        end
        self
      end

      # Joins execution by stepping until the Fiber is no longer alive.
      # @param limit [Numeric, nil] ignored
      # @return [self]
      # @api private
      def join(_limit = nil)
        step while @fiber.alive?
        self
      end
    end
  end
end
