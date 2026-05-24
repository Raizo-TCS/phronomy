# frozen_string_literal: true

module Phronomy
  # Manages a bounded set of concurrent {Task}s with structured concurrency.
  #
  # Enforces an upper bound on simultaneously running tasks (+limit+).
  # When the limit is reached, {#spawn} blocks the caller until a slot
  # becomes available.  Results are always returned in the order tasks
  # were spawned, regardless of completion order.
  #
  # A configurable +failure_policy+ controls how errors propagate:
  # - +:fail_fast+ (default) — cancels all remaining tasks on the first error
  # - +:collect_all+ — waits for every task to complete, then raises the first error
  # - +:skip_failed+ — ignores failed tasks and returns only successful results
  #
  # {#cancel_all!} cancels every task in the group and joins them, guaranteeing
  # that the active child task count reaches zero before returning.
  #
  # @example Parallel tool calls with a concurrency cap
  #   group = Phronomy::TaskGroup.new(limit: 5)
  #   tasks = items.map { |item| group.spawn { process(item) } }
  #   results = group.await_all   # Array in spawn order
  #
  # @example Collect-all failure policy
  #   group = Phronomy::TaskGroup.new(failure_policy: :collect_all)
  #   …
  class TaskGroup
    # Valid failure policies.
    FAILURE_POLICIES = %i[fail_fast collect_all skip_failed].freeze

    # @param limit          [Integer, Float::INFINITY] maximum simultaneous active tasks
    # @param failure_policy [Symbol] one of {FAILURE_POLICIES} (default +:fail_fast+)
    def initialize(limit: Float::INFINITY, failure_policy: :fail_fast)
      raise ArgumentError, "unknown failure_policy: #{failure_policy}" unless FAILURE_POLICIES.include?(failure_policy)

      @limit = limit
      @failure_policy = failure_policy
      @tasks = []
      @mutex = Mutex.new
      @cond = ConditionVariable.new
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
        block.call
      ensure
        release_slot!
      end

      @mutex.synchronize { @tasks << task }
      task
    end

    # Waits for all spawned tasks to complete.
    # Returns results in spawn order.
    #
    # Failure behaviour is controlled by the +failure_policy+ set at
    # construction time:
    # - +:fail_fast+    — raises the first error after cancelling unfinished tasks
    # - +:collect_all+  — waits for all tasks, then raises the first error
    # - +:skip_failed+  — returns only the values of successful tasks
    #
    # @return [Array] results in spawn order (or successful-only for :skip_failed)
    # @raise [Exception] when any task failed (except :skip_failed)
    def await_all
      tasks = @mutex.synchronize { @tasks.dup }
      return [] if tasks.empty?

      collected = tasks.map do |task|
        {value: task.await, error: nil}
      rescue => e
        tasks.each { |t| t.cancel! unless t.done? } if @failure_policy == :fail_fast
        {value: nil, error: e}
      end

      errors = collected.filter_map { |r| r[:error] }

      case @failure_policy
      when :skip_failed
        collected.filter_map { |r| r[:value] unless r[:error] }
      else
        raise errors.first if errors.any?

        collected.map { |r| r[:value] }
      end
    end

    # Cancels all tasks currently in the group and waits for each to finish.
    # After this method returns, the active child task count is guaranteed to
    # be zero.
    #
    # Note: if a task is cancelled before its block has started executing, the
    # internal +ensure+ clause inside the block may not run, so @active is
    # reset explicitly after all tasks are joined.
    #
    # @return [self]
    def cancel_all!
      tasks = @mutex.synchronize { @tasks.dup }
      tasks.each(&:cancel!)
      tasks.each do |t|
        t.join
      rescue
        nil
      end
      # Force @active to zero: tasks cancelled before block execution starts
      # may not decrement @active via their ensure clause.
      @mutex.synchronize do
        @active = 0
        @cond.broadcast
      end
      self
    end

    # Returns the number of currently executing child tasks.
    # @return [Integer]
    def active_task_count
      @mutex.synchronize { @active }
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
