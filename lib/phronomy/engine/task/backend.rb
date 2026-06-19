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
      # @api private
      def initialize(task:, &block)
        @task = task
        @block = block
      end

      # Blocks until the task completes and returns its value.
      # Re-raises errors from the block.
      # @return [Object]
      # @raise [Exception]
      # @api private
      def await
        raise NotImplementedError, "#{self.class}#await not implemented"
      end

      # Returns +true+ while execution is still ongoing.
      # @return [Boolean]
      # @api private
      def alive?
        raise NotImplementedError, "#{self.class}#alive? not implemented"
      end

      # Requests cancellation.
      # Thread-based backends may use +Thread#raise+; cooperative backends
      # should mark the task cancelled and rely on {Task.checkpoint!}.
      # @return [self]
      # @api private
      def cancel!
        raise NotImplementedError, "#{self.class}#cancel! not implemented"
      end

      # Joins the execution context with an optional timeout.
      # Returns +nil+ when a non-nil +limit+ expires before completion,
      # matching +Thread#join+ semantics.
      # @param limit [Numeric, nil]
      # @return [Object, nil]
      # @api private
      def join(limit = nil)
        raise NotImplementedError, "#{self.class}#join not implemented"
      end

      # Returns the task's result value once it has reached a terminal state.
      # Only valid to call after the task is done.
      # Subclasses should override if they store the result.
      # @return [Object, nil]
      # @api private
      def completed_value
        nil
      end

      # Returns the exception raised by the task, or +nil+ on success/cancellation.
      # Only valid to call after the task is done.
      # Subclasses should override if they store errors.
      # @return [Exception, nil]
      # @api private
      def completed_error
        nil
      end

      private

      attr_reader :task, :block
    end
  end
end
