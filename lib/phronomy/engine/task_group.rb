# frozen_string_literal: true

module Phronomy
  # Manages a bounded set of concurrent {Task}s with structured concurrency.
  class TaskGroup
    FAILURE_POLICIES = %i[fail_fast collect_all skip_failed].freeze

    # @param limit [Integer, Float::INFINITY]
    # @param failure_policy [Symbol]
    # @param runtime [Runtime] runtime authority used to spawn every child Task
    # @api private
    def initialize(runtime:, limit: Float::INFINITY, failure_policy: :fail_fast)
      unless FAILURE_POLICIES.include?(failure_policy)
        raise ArgumentError, "unknown failure_policy: #{failure_policy}"
      end
      unless runtime
        raise ArgumentError, "runtime is required"
      end

      @limit = limit
      @failure_policy = failure_policy
      @runtime = runtime
      @tasks = []
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @active = 0
    end

    # @api private
    def spawn(&block)
      wait_for_slot!

      task = @runtime.spawn(name: "task-group-worker") do
        block.call
      ensure
        release_slot!
      end

      @mutex.synchronize { @tasks << task }
      task
    end

    # @api private
    def await_all
      tasks = @mutex.synchronize { @tasks.dup }
      return [] if tasks.empty?

      if Phronomy::Runtime::Scheduler.current
        _await_all_cooperative(tasks)
      else
        _await_all_threaded(tasks)
      end
    end

    private

    def _await_all_cooperative(tasks)
      completion_q = Phronomy::Concurrency::AsyncQueue.new
      tasks.each_with_index do |task, idx|
        task.on_complete do |value, error|
          completion_q.push({index: idx, value: value, error: error})
        end
      end

      entries = Array.new(tasks.length)
      cancelled = false
      fail_fast_error = nil

      tasks.length.times do
        entry = completion_q.pop
        entries[entry[:index]] = entry

        if entry[:error] && @failure_policy == :fail_fast && !cancelled
          cancelled = true
          fail_fast_error = entry[:error]
          tasks.each { |task| task.cancel! unless task.done? }
        end
      end

      case @failure_policy
      when :fail_fast
        raise fail_fast_error if fail_fast_error
        entries.map { |entry| entry[:value] }
      when :skip_failed
        entries.filter_map { |entry| entry[:value] unless entry[:error] }
      else
        errors = entries.filter_map { |entry| entry[:error] }
        raise errors.first if errors.any?
        entries.map { |entry| entry[:value] }
      end
    end

    def _await_all_threaded(tasks)
      completion_q = Queue.new
      tasks.each_with_index do |task, idx|
        task.on_complete do |value, error|
          completion_q.push({index: idx, value: value, error: error})
        end
      end

      entries = Array.new(tasks.length)
      cancelled = false
      fail_fast_error = nil

      tasks.length.times do
        entry = completion_q.pop
        entries[entry[:index]] = entry

        if entry[:error] && @failure_policy == :fail_fast && !cancelled
          cancelled = true
          fail_fast_error = entry[:error]
          tasks.each { |task| task.cancel! unless task.done? }
        end
      end

      case @failure_policy
      when :fail_fast
        raise fail_fast_error if fail_fast_error
        entries.map { |entry| entry[:value] }
      when :skip_failed
        entries.filter_map { |entry| entry[:value] unless entry[:error] }
      else
        errors = entries.filter_map { |entry| entry[:error] }
        raise errors.first if errors.any?
        entries.map { |entry| entry[:value] }
      end
    end

    public

    # @api private
    def cancel_all!
      tasks = @mutex.synchronize { @tasks.dup }
      tasks.each(&:cancel!)
      tasks.each do |task|
        task.join
      rescue
        nil
      end

      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler && @coop_signal
        @active = 0
        scheduler.raise_signal_all(@coop_signal)
      else
        @mutex.synchronize do
          @active = 0
          @cond.broadcast
        end
      end
      self
    end

    # @api private
    def active_task_count
      @mutex.synchronize { @active }
    end

    private

    def wait_for_slot!
      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler
        @coop_signal ||= scheduler.new_signal
        loop do
          if @active < @limit
            @active += 1
            return
          end
          scheduler.wait_for_signal(@coop_signal)
        end
      else
        @mutex.synchronize do
          @cond.wait(@mutex) while @active >= @limit
          @active += 1
        end
      end
    end

    def release_slot!
      scheduler = Phronomy::Runtime::Scheduler.current
      if scheduler && @coop_signal
        @active -= 1
        scheduler.raise_signal(@coop_signal)
      else
        @mutex.synchronize do
          @active -= 1
          @cond.signal
        end
      end
    end
  end
end
