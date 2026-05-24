# frozen_string_literal: true

require_relative "runtime/scheduler"
require_relative "runtime/thread_scheduler"
require_relative "runtime/fake_scheduler"

module Phronomy
  # Central authority for concurrent primitives.
  #
  # +Runtime+ is the single place that creates {Task}s, {TaskGroup}s, and
  # manages the lifecycle of all concurrency in Phronomy.  It owns:
  #
  # * a pluggable {Scheduler} (default: {ThreadScheduler})
  # * a task registry for graceful shutdown
  # * the shared {BlockingAdapterPool}
  #
  # In production, use the process-wide singleton via {.instance}.
  # In tests, construct a Runtime with a {FakeScheduler} to run tasks
  # synchronously without spawning additional threads:
  #
  # @example Production usage
  #   group = Phronomy::Runtime.instance.task_group(limit: 4)
  #   tools.each { |t| group.spawn { t.call } }
  #   results = group.await_all
  #
  # @example Test usage — no extra threads
  #   runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
  #   task = runtime.spawn { 42 }
  #   expect(task.await).to eq(42)
  class Runtime
    # Returns the process-wide default Runtime.
    # @return [Runtime]
    def self.instance
      @instance ||= new
    end

    # Replaces the process-wide default Runtime.  Useful in tests.
    # @param runtime [Runtime]
    # @return [Runtime]
    def self.instance=(runtime)
      @instance = runtime
    end

    # @param scheduler [Scheduler] execution backend (default: {ThreadScheduler})
    def initialize(scheduler: ThreadScheduler.new)
      @scheduler = scheduler
      @task_mutex = Mutex.new
      @tasks = []
    end

    # Creates a new {TaskGroup} with an optional concurrency cap.
    #
    # @param limit [Integer, Float::INFINITY] max simultaneous tasks
    # @return [TaskGroup]
    def task_group(limit: Float::INFINITY)
      TaskGroup.new(limit: limit)
    end

    # Spawns a single {Task} using the runtime's scheduler.
    #
    # The spawned task is registered in the task registry so {#shutdown}
    # can wait for it to complete.
    #
    # @param name [String, nil] optional label for debugging
    # @yield block to execute (concurrently or synchronously, depending on
    #   the configured scheduler)
    # @return [Task]
    def spawn(name: nil, &block)
      task = @scheduler.spawn(name: name, parent: Task.current, &block)
      @task_mutex.synchronize { @tasks << task }
      task
    end

    # Returns the shared {BlockingAdapterPool} for this Runtime.
    # All blocking I/O (LLM HTTP, MCP, ActiveRecord, Redis) should be
    # submitted through this pool.
    #
    # Pool settings default to 10 workers / 100-deep queue.  Override by
    # constructing a Runtime with custom pool options or by replacing the
    # shared Runtime via {.instance=} in tests.
    #
    # @param pool_size  [Integer] worker thread count (default: 10)
    # @param queue_size [Integer] max pending operations (default: 100)
    # @return [BlockingAdapterPool]
    def blocking_io(pool_size: 10, queue_size: 100)
      @blocking_io ||= BlockingAdapterPool.new(pool_size: pool_size, queue_size: queue_size)
    end

    # Waits for all registered tasks to finish, then shuts down the
    # blocking adapter pool (if it was started).
    #
    # Call this before process exit to avoid leaving orphaned threads or
    # pending work items.
    #
    # @return [void]
    def shutdown
      tasks = @task_mutex.synchronize { @tasks.dup }
      tasks.each do |t|
        t.join
      rescue
        nil
      end
      @blocking_io&.shutdown
    end
  end
end
