# frozen_string_literal: true

require_relative "runtime/scheduler"
require_relative "runtime/thread_scheduler"
require_relative "runtime/fake_scheduler"
require_relative "runtime/timer_queue"

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
      @timer_queue = nil
      @timer_mutex = Mutex.new
      @pools = {}
      @pool_mutex = Mutex.new
      @gates = {}
      @gate_mutex = Mutex.new
      @starvation_mutex = Mutex.new
      @tasks_waiting_over_threshold = 0
    end

    # Returns (or lazily creates) the {ConcurrencyGate} for the named resource.
    #
    # Gate caps are read from the global {Phronomy::Configuration} when the gate
    # is first accessed; subsequent calls return the cached gate.  To change the
    # cap at runtime, call {#reset_gate} first.
    #
    # @param name [:agent, :tool, :workflow, :llm, :rag, :vector] resource name
    # @return [ConcurrencyGate]
    def gate(name)
      @gate_mutex.synchronize do
        @gates[name.to_sym] ||= _build_gate(name.to_sym)
      end
    end

    # Drops the cached gate for +name+ so that the next call to {#gate} rebuilds
    # it from the current configuration.  Useful in tests.
    #
    # @param name [Symbol]
    # @return [void]
    def reset_gate(name)
      @gate_mutex.synchronize { @gates.delete(name.to_sym) }
    end

    # Cooperative yield point.
    #
    # Signals the scheduler that the current task is willing to give up CPU time
    # so that other ready tasks can run.  On the default {ThreadScheduler} this
    # calls +Thread.pass+.  On a future fiber-based scheduler this would switch
    # to the next runnable fiber.
    #
    # When +blocking_detect_threshold_ms+ is configured, checks whether the
    # current task has exceeded that threshold without yielding; if so, emits a
    # warning via the configured logger and increments
    # +tasks_waiting_over_threshold+.
    #
    # Call this inside tight loops or CPU-intensive sections of tool +execute+
    # methods and Workflow actions to keep the scheduler responsive.
    #
    # @return [void]
    def yield
      if (threshold = Phronomy.configuration.blocking_detect_threshold_ms)
        slice_start = Task.current_cpu_slice_start_ms
        if slice_start
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - slice_start
          if elapsed > threshold
            name = Task.current&.name || "unknown"
            Phronomy.configuration.logger&.warn(
              "[Phronomy] CPU-bound task detected: '#{name}' ran #{elapsed.round}ms " \
              "without yielding (threshold: #{threshold}ms)"
            )
            @starvation_mutex.synchronize { @tasks_waiting_over_threshold += 1 }
          end
        end
      end
      Task.record_yield!
      @scheduler.yield
    end

    # Number of times a task has exceeded the CPU-bound detection threshold
    # (i.e. ran longer than +blocking_detect_threshold_ms+ without yielding).
    # Resets to 0 when the Runtime is recreated.
    # @return [Integer]
    def tasks_waiting_over_threshold
      @starvation_mutex.synchronize { @tasks_waiting_over_threshold }
    end

    # Cooperative yield point with a call-count gate.
    #
    # Increments a per-thread counter and calls {#yield} when the counter
    # reaches a multiple of +every+.  The counter is thread-local so concurrent
    # tasks each maintain their own independent loop counter without requiring
    # a mutex.
    #
    # @example
    #   data.each_with_index do |row, i|
    #     process(row)
    #     Phronomy::Runtime.instance.yield_if_needed(every: 500)
    #   end
    #
    # @param every [Integer] yield once every N calls (default: 1000)
    # @return [void]
    def yield_if_needed(every: 1000)
      # Delegate Thread.current access to Task so that runtime.rb stays outside
      # the Thread.current allowlist (Issue #302).
      self.yield if (Task.increment_yield_counter! % every).zero?
    end

    # Creates a new {TaskGroup} with an optional concurrency cap.
    #
    # @param limit          [Integer, Float::INFINITY] max simultaneous tasks
    # @param failure_policy [Symbol] one of :fail_fast, :collect_all, :skip_failed (default :fail_fast)
    # @return [TaskGroup]
    def task_group(limit: Float::INFINITY, failure_policy: :fail_fast)
      TaskGroup.new(limit: limit, failure_policy: failure_policy)
    end

    # Spawns a single {Task} using the runtime's scheduler.
    #
    # The spawned task is registered in the task registry so {#shutdown}
    # can wait for it to complete.  The task is automatically deregistered
    # from the registry when it finishes (success, failure, or cancellation)
    # so long-lived runtimes do not accumulate stale references.
    #
    # @param name [String, nil] optional label for debugging
    # @yield block to execute (concurrently or synchronously, depending on
    #   the configured scheduler)
    # @return [Task]
    def spawn(name: nil, &block)
      task = @scheduler.spawn(name: name, parent: Task.current) do
        block.call
      ensure
        current = Task.current
        @task_mutex.synchronize { @tasks.delete(current) } if current
      end
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
      @blocking_io ||= BlockingAdapterPool.new(name: :default, pool_size: pool_size, queue_size: queue_size)
    end

    # Returns (or lazily creates) a named {BlockingAdapterPool}.
    #
    # Named pools allow per-subsystem thread-budget control and observability.
    # Recommended pool names: +:llm+, +:mcp+, +:db+, +:redis+, +:tool+.
    # Each pool gets its own dedicated worker threads labelled with the pool name.
    #
    # @example
    #   runtime.pool(:llm)            # default size (10 workers)
    #   runtime.pool(:db, size: 20)   # custom size
    #
    # @param name      [Symbol, String] pool identifier
    # @param size      [Integer] worker thread count (default: 10)
    # @param queue_size [Integer] max pending operations (default: 100)
    # @return [BlockingAdapterPool]
    def pool(name, size: 10, queue_size: 100)
      @pool_mutex.synchronize do
        @pools[name.to_sym] ||= BlockingAdapterPool.new(
          name: name,
          pool_size: size,
          queue_size: queue_size
        )
      end
    end

    # Returns the shared {TimerQueue} for this Runtime.
    #
    # All deadline-based cancellation should be registered here instead of
    # spawning one-off sleep threads.  Lazily created on first access.
    #
    # @return [TimerQueue]
    def timer_queue
      @timer_mutex.synchronize { @timer_queue ||= TimerQueue.new }
    end

    # Waits for all registered tasks to finish, then shuts down the
    # EventLoop (if active), blocking adapter pool, named pools, and timer queue
    # (if they were started).
    #
    # When EventLoop mode is enabled, all pending Workflow and Agent FSM events
    # are drained before pools are shut down, ensuring in-flight sessions
    # complete cleanly.
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
      # Drain EventLoop events before stopping pools so that in-flight
      # Workflow / Agent FSM sessions can complete their final LLM calls.
      if Phronomy.configuration.event_loop
        Phronomy::EventLoop.instance.stop(drain: true)
      end
      @blocking_io&.shutdown
      pools = @pool_mutex.synchronize { @pools.values.dup }
      pools.each(&:shutdown)
      @timer_mutex.synchronize { @timer_queue&.shutdown }
    end

    private

    GATE_CONFIG_MAP = {
      agent: :max_concurrent_agent_tasks,
      tool: :max_concurrent_tool_tasks,
      workflow: :max_concurrent_workflow_tasks,
      llm: :max_concurrent_llm_calls,
      rag: :max_concurrent_rag_fetches,
      vector: :max_concurrent_vector_searches
    }.freeze
    private_constant :GATE_CONFIG_MAP

    def _build_gate(name)
      config_key = GATE_CONFIG_MAP[name]
      max = config_key ? Phronomy.configuration.public_send(config_key) : nil
      ConcurrencyGate.new(max_concurrent: max, name: name)
    end
  end
end
