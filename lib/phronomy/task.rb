# frozen_string_literal: true

module Phronomy
  # A single unit of concurrent work.
  #
  # Wraps a Ruby Thread internally so that callers never reference Thread
  # directly. The interface is intentionally minimal so that a future
  # implementation can swap the backing primitive (Fiber, Ractor, etc.)
  # without changing call sites.
  #
  # @example Basic usage
  #   task = Phronomy::Task.spawn { expensive_io() }
  #   result = task.await   # blocks until done, re-raises errors
  #
  # @example Cancel a running task
  #   task = Phronomy::Task.spawn { loop { sleep 0.01 } }
  #   task.cancel!
  class Task
    # Spawns a new task executing +block+ concurrently.
    #
    # @param name [String, nil] optional human-readable label for debugging
    # @yieldreturn [Object] the task result
    # @return [Task]
    def self.spawn(name: nil, &block)
      new(name: name, &block)
    end

    # @return [String, nil] optional human-readable label
    attr_reader :name

    # @param name [String, nil] optional label
    # @api private use {.spawn} instead
    def initialize(name: nil, &block)
      @name   = name
      @done   = false
      @value  = nil
      @error  = nil
      @mutex  = Mutex.new
      @thread = Thread.new do
        Thread.current.name = name if name
        begin
          @value = block.call
        rescue => e
          @error = e
        ensure
          @mutex.synchronize { @done = true }
        end
      end
    end

    # Blocks until the task completes and returns its value.
    # Re-raises any exception raised inside the block.
    #
    # @return [Object] the result produced by the block
    # @raise [Exception] if the block raised an error
    def await
      @thread.join
      raise @error if @error

      @value
    end

    # Returns +true+ once the task has finished (success or error).
    # @return [Boolean]
    def done?
      @mutex.synchronize { @done }
    end

    # Requests cancellation by raising {Phronomy::CancellationError} in the
    # underlying thread.  Because Ruby threads can rescue arbitrary exceptions,
    # cancellation is cooperative: the block must not suppress the error.
    #
    # @return [self]
    def cancel!
      @thread.raise(Phronomy::CancellationError, "Task cancelled") if @thread.alive?
      self
    end

    # Joins the underlying thread, optionally with a timeout.
    # Returns the Thread object (nil when a non-nil limit expires before the
    # thread finishes, matching Thread#join semantics).
    #
    # @param limit [Numeric, nil] seconds to wait; nil waits indefinitely
    # @return [Thread, nil]
    def join(limit = nil)
      @thread.join(limit)
    end

    # Returns +true+ while the task's block is still executing.
    # @return [Boolean]
    def alive?
      @thread.alive?
    end
  end
end
