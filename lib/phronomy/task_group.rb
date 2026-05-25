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
    # @param runtime        [Runtime, nil] runtime used to spawn tasks via {Runtime#spawn};
    #   when +nil+, tasks are created directly via +Task.new+ (backward-compatible mode).
    #   Pass +runtime: self+ from {Runtime#task_group} to keep task execution consistent
    #   with the configured scheduler backend.
    # @api private
    def initialize(limit: Float::INFINITY, failure_policy: :fail_fast, runtime: nil)
      raise ArgumentError, "unknown failure_policy: #{failure_policy}" unless FAILURE_POLICIES.include?(failure_policy)

      @limit = limit
      @failure_policy = failure_policy
      @runtime = runtime
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
    # @api private
    def spawn(&block)
      wait_for_slot!

      task = if @runtime
        @runtime.spawn(name: "task-group-worker") do
          block.call
        ensure
          release_slot!
        end
      else
        Task.new do
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
    #
    # Failure behaviour is controlled by the +failure_policy+ set at
    # construction time:
    # - +:fail_fast+    — raises the first error after cancelling unfinished tasks
    # - +:collect_all+  — waits for all tasks, then raises the first error
    # - +:skip_failed+  — returns only the values of successful tasks
    #
    # @return [Array] results in spawn order (or successful-only for :skip_failed)
    # @raise [Exception] when any task failed (except :skip_failed)
    # @api private
    def await_all
      tasks = @mutex.synchronize { @tasks.dup }
      return [] if tasks.empty?

      # Use Task#on_complete callbacks instead of spawning N additional watcher
      # tasks (Issue #328).  on_complete receives the task's value and error
      # directly — no await call is needed, eliminating the risk of a self-join
      # when the callback fires inside the task's own execution thread.
      completion_q = Queue.new
      tasks.each_with_index do |task, idx|
        task.on_complete do |value, error|
          completion_q.push({index: idx, value: value, error: error})
        end
      end

      entries = Array.new(tasks.length)
      cancelled = false
      # The error that triggered fail_fast cancellation (tracked separately so
      # we raise it rather than a secondary CancellationError from cancelled tasks).
      fail_fast_error = nil

      tasks.length.times do
        entry = completion_q.pop
        entries[entry[:index]] = entry

        if entry[:error] && @failure_policy == :fail_fast && !cancelled
          cancelled = true
          fail_fast_error = entry[:error]
          tasks.each { |t| t.cancel! unless t.done? }
        end
      end

      case @failure_policy
      when :fail_fast
        raise fail_fast_error if fail_fast_error
        entries.map { |r| r[:value] }
      when :skip_failed
        entries.filter_map { |r| r[:value] unless r[:error] }
      else # :collect_all
        errors = entries.filter_map { |r| r[:error] }
        raise errors.first if errors.any?
        entries.map { |r| r[:value] }
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
    # @api private
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
    # @api private
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
