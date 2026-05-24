# frozen_string_literal: true

module Phronomy
  class Task
    # Abstract base class for Task execution backends.
    #
    # A backend encapsulates the execution primitive (Thread, Fiber, etc.) and
    # the lifecycle transitions it drives.  Concrete backends must implement all
    # abstract methods.  The default concrete implementation is {ThreadBackend}.
    #
    # Backends receive a reference to the owning {Task} so they can call
    # {Task#transition!} at the appropriate lifecycle points.
    class Backend
      # @param task  [Task] the owning Task (used for status callbacks)
      # @param block [Proc] the work to execute
      def initialize(task:, &block)
        @task = task
        @block = block
      end

      # Blocks until the task completes and returns its value.
      # Re-raises errors from the block.
      # @return [Object]
      # @raise [Exception]
      def await
        raise NotImplementedError, "#{self.class}#await not implemented"
      end

      # Returns +true+ while execution is still ongoing.
      # @return [Boolean]
      def alive?
        raise NotImplementedError, "#{self.class}#alive? not implemented"
      end

      # Requests cancellation.
      # Thread-based backends may use +Thread#raise+; cooperative backends
      # should mark the task cancelled and rely on {Task.checkpoint!}.
      # @return [self]
      def cancel!
        raise NotImplementedError, "#{self.class}#cancel! not implemented"
      end

      # Joins the execution context with an optional timeout.
      # Returns +nil+ when a non-nil +limit+ expires before completion,
      # matching +Thread#join+ semantics.
      # @param limit [Numeric, nil]
      # @return [Object, nil]
      def join(limit = nil)
        raise NotImplementedError, "#{self.class}#join not implemented"
      end

      private

      attr_reader :task, :block
    end
  end
end
