# frozen_string_literal: true

module Phronomy
  # Manages a bounded set of concurrent {Task}s.
  #
  # Enforces an upper bound on simultaneously running tasks (+limit+).
  # When the limit is reached, {#spawn} blocks the caller until a slot
  # becomes available.  Results are always returned in the order tasks
  # were spawned, regardless of completion order.
  #
  # @example Parallel tool calls with a concurrency cap
  #   group = Phronomy::TaskGroup.new(limit: 5)
  #   tasks = items.map { |item| group.spawn { process(item) } }
  #   results = group.await_all   # Array in spawn order
  class TaskGroup
    # @param limit [Integer, Float::INFINITY] maximum simultaneous active tasks
    def initialize(limit: Float::INFINITY)
      @limit  = limit
      @tasks  = []
      @mutex  = Mutex.new
      @cond   = ConditionVariable.new
      @active = 0
    end

    # Spawns a new task within the group.
    # Blocks if the number of currently active tasks equals +limit+.
    #
    # @yield block to execute concurrently
    # @return [Task] the spawned task
    def spawn(&block)
      wait_for_slot!

      task = Task.new do
        begin
          block.call
        ensure
          release_slot!
        end
      end

      @mutex.synchronize { @tasks << task }
      task
    end

    # Waits for all spawned tasks to complete.
    # Returns results in spawn order.
    # If any task raised an error, re-raises the first error after all tasks
    # have finished (so resources are not leaked).
    #
    # @return [Array] results in spawn order
    # @raise [Exception] the first error encountered, if any
    def await_all
      tasks = @mutex.synchronize { @tasks.dup }
      results = tasks.map do |task|
        begin
          {value: task.await, error: nil}
        rescue => e
          {value: nil, error: e}
        end
      end

      first_error = results.find { |r| r[:error] }&.fetch(:error)
      raise first_error if first_error

      results.map { |r| r[:value] }
    end

    # Cancels all tasks currently in the group.
    # @return [self]
    def cancel_all!
      @mutex.synchronize { @tasks.dup }.each(&:cancel!)
      self
    end

    private

    def wait_for_slot!
      @mutex.synchronize do
        @cond.wait(@mutex) while @active >= @limit
        @active += 1
      end
    end

    def release_slot!
      @mutex.synchronize do
        @active -= 1
        @cond.signal
      end
    end
  end
end
