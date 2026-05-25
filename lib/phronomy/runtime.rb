# frozen_string_literal: true

require_relative "runtime/scheduler"
require_relative "runtime/thread_scheduler"
require_relative "runtime/fake_scheduler"
require_relative "runtime/deterministic_scheduler"
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
    #
    # Auto-creates an instance using the scheduler backend specified by
    # +Phronomy.configuration.runtime_backend+:
    # - +:thread+ (default) — {ThreadScheduler} (one OS thread per task)
    # - +:immediate+ — {FakeScheduler} (synchronous, no extra threads)
    # - +:cooperative+ — deprecated alias for +:immediate+
    #
    # @return [Runtime]
    # @api private
    def self.instance
      @instance ||= begin
        scheduler = case Phronomy.configuration.runtime_backend
        when :immediate, :cooperative
          FakeScheduler.new
        else
          ThreadScheduler.new
        end
        new(scheduler: scheduler)
      end
    end

    # Replaces the process-wide default Runtime.  Useful in tests.
    # @param runtime [Runtime]
    # @return [Runtime]
    # @api private
    def self.instance=(runtime)
      @instance = runtime
    end

    # Returns +true+ when the calling thread is executing inside an active
    # scheduler task (i.e. {Task.current} is non-nil).  Code running inside
    # a {Runtime#spawn} block is always in a scheduler context.
    #
    # Use this to detect potential scheduler-blocking calls:
    #   if Phronomy::Runtime.in_scheduler_context?
    #     Phronomy.configuration.logger&.warn("blocking call inside scheduler task")
    #   end
    #
    # @return [Boolean]
    # @api private
    def self.in_scheduler_context?
      !Task.current.nil?
    end

    # The scheduler backing this runtime instance.
    # @return [Scheduler]
    attr_reader :scheduler

    # @param scheduler [Scheduler] execution backend (default: {ThreadScheduler})
    # @api private
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
      # Task-centric metrics (Issue #307)
      @metrics_mutex = Mutex.new
      @active_tasks_by_type = Hash.new(0)   # type => count
      @wait_times_ms = []                    # ring buffer of wait_ms floats
      @run_times_ms = []                     # ring buffer of run_ms floats
      @cancelled_by_type = Hash.new(0)
      @failed_by_type = Hash.new(0)
      @metrics_window = 1000                 # keep last N samples
    end

    # Returns (or lazily creates) the {ConcurrencyGate} for the named resource.
    #
    # Gate caps are read from the global {Phronomy::Configuration} when the gate
    # is first accessed; subsequent calls return the cached gate.  To change the
    # cap at runtime, call {#reset_gate} first.
    #
    # @param name [:agent, :tool, :workflow, :llm, :rag, :vector] resource name
    # @return [ConcurrencyGate]
    # @api private
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
    # @api private
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
    # @api private
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
    # @api private
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
    # @api private
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
    # @api private
    def task_group(limit: Float::INFINITY, failure_policy: :fail_fast)
      TaskGroup.new(limit: limit, failure_policy: failure_policy, runtime: self)
    end

    # Spawns a single {Task} using the runtime's scheduler.
    #
    # The spawned task is registered in the task registry so {#shutdown}
    # can wait for it to complete.  The task is automatically deregistered
    # from the registry when it finishes (success, failure, or cancellation)
    # so long-lived runtimes do not accumulate stale references.
    #
    # Task names beginning with a recognised type prefix are counted in the
    # task-centric metrics returned by {#task_snapshot}.  Recognised prefixes:
    # +agent-+, +tool-+, +workflow-+, +rag-+, +llm-+, +vector-+.
    #
    # @param name [String, nil] optional label for debugging
    # @yield block to execute (concurrently or synchronously, depending on
    #   the configured scheduler)
    # @return [Task]
    # @api private
    def spawn(name: nil, &block)
      type = _task_type(name)
      spawn_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      _record_task_start(type)

      task = @scheduler.spawn(name: name, parent: Task.current) do
        run_start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        _record_wait_time(run_start - spawn_at)
        begin
          result = block.call
          _record_task_end(type, :completed, run_start)
          result
        rescue CancellationError
          _record_task_end(type, :cancelled, run_start)
          raise
        rescue => e
          _record_task_end(type, :failed, run_start)
          raise e
        ensure
          current = Task.current
          @task_mutex.synchronize { @tasks.delete(current) } if current
        end
      end
      # Skip registration for tasks that already completed synchronously
      # (e.g. ImmediateBackend used in tests runs the block inline, so
      # `ensure` fires before we reach this line and the delete is a no-op).
      @task_mutex.synchronize { @tasks << task unless task.done? }
      task
    end

    # Returns a snapshot of task-centric metrics for the current Runtime.
    #
    # | Key | Description |
    # |-----|-------------|
    # | `active_agent_tasks`      | currently running agent spawns |
    # | `active_tool_tasks`       | currently running tool spawns |
    # | `active_workflow_tasks`   | currently running workflow spawns |
    # | `active_rag_tasks`        | currently running RAG fetches |
    # | `active_llm_tasks`        | currently running LLM calls |
    # | `task_wait_time_p50_ms`   | p50 spawn-to-start latency (ms) |
    # | `task_wait_time_p95_ms`   | p95 spawn-to-start latency (ms) |
    # | `task_run_time_p50_ms`    | p50 execution duration (ms) |
    # | `task_run_time_p95_ms`    | p95 execution duration (ms) |
    # | `cancelled_tasks`         | total cancelled task count |
    # | `failed_tasks`            | total failed task count |
    # | `non_yield_duration_max_ms` | max observed CPU-slice duration (ms) |
    #
    # @return [Hash{Symbol => Numeric}]
    # @api private
    def task_snapshot
      @metrics_mutex.synchronize do
        active = @active_tasks_by_type.dup
        wait = @wait_times_ms.dup
        run = @run_times_ms.dup
        cancelled = @cancelled_by_type.values.sum
        failed = @failed_by_type.values.sum
        starvation_max = @tasks_waiting_over_threshold
        {
          active_agent_tasks: active[:agent].to_i,
          active_tool_tasks: active[:tool].to_i,
          active_workflow_tasks: active[:workflow].to_i,
          active_rag_tasks: active[:rag].to_i,
          active_llm_tasks: active[:llm].to_i,
          task_wait_time_p50_ms: _percentile(wait, 50),
          task_wait_time_p95_ms: _percentile(wait, 95),
          task_run_time_p50_ms: _percentile(run, 50),
          task_run_time_p95_ms: _percentile(run, 95),
          cancelled_tasks: cancelled,
          failed_tasks: failed,
          non_yield_duration_max_ms: starvation_max
        }
      end
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
    # @api private
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
    # @api private
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
    # @api private
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
    # @api private
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

    TASK_TYPE_PREFIXES = %w[agent tool workflow rag llm vector].freeze
    private_constant :TASK_TYPE_PREFIXES

    def _build_gate(name)
      config_key = GATE_CONFIG_MAP[name]
      max = config_key ? Phronomy.configuration.public_send(config_key) : nil
      ConcurrencyGate.new(max_concurrent: max, name: name)
    end

    def _task_type(name)
      return :other if name.nil?

      prefix = TASK_TYPE_PREFIXES.find { |p| name.to_s.start_with?("#{p}-") }
      prefix ? prefix.to_sym : :other
    end

    def _record_task_start(type)
      @metrics_mutex.synchronize { @active_tasks_by_type[type] += 1 }
    end

    def _record_wait_time(wait_ms)
      @metrics_mutex.synchronize do
        @wait_times_ms << wait_ms
        @wait_times_ms.shift if @wait_times_ms.size > @metrics_window
      end
    end

    def _record_task_end(type, outcome, run_start_ms)
      run_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - run_start_ms
      @metrics_mutex.synchronize do
        @active_tasks_by_type[type] = [@active_tasks_by_type[type] - 1, 0].max
        @run_times_ms << run_ms
        @run_times_ms.shift if @run_times_ms.size > @metrics_window
        case outcome
        when :cancelled then @cancelled_by_type[type] += 1
        when :failed then @failed_by_type[type] += 1
        end
      end
    end

    def _percentile(samples, pct)
      return 0.0 if samples.empty?

      sorted = samples.sort
      idx = ((pct / 100.0) * (sorted.size - 1)).round
      sorted[idx].round(3)
    end
  end
end
