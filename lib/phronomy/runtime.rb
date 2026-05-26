# frozen_string_literal: true

require_relative "runtime/scheduler"
require_relative "runtime/thread_scheduler"
require_relative "runtime/fake_scheduler"
require_relative "runtime/deterministic_scheduler"
require_relative "runtime/timer_queue"
require_relative "runtime/scheduler_timer_adapter"
require_relative "runtime/task_registry"
require_relative "runtime/runtime_metrics"
require_relative "runtime/gate_registry"
require_relative "runtime/pool_registry"
require_relative "runtime/timer_service"

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
    # - +:fiber+ — {DeterministicScheduler} in autorun mode (EXPERIMENTAL;
    #   Fiber-based synchronous execution; not yet suitable for production
    #   because it uses virtual time rather than real wall-clock timers)
    # - +:cooperative+ — deprecated alias for +:immediate+
    #
    # @return [Runtime]
    # @api private
    def self.instance
      @instance ||= begin
        scheduler = case Phronomy.configuration.runtime_backend
        when :cooperative
          Phronomy.configuration.logger&.warn(
            "[phronomy] runtime_backend: :cooperative is a deprecated alias for :immediate. " \
            "Use :immediate for synchronous/test execution. " \
            ":cooperative will be reassigned when a real cooperative Fiber-based scheduler is available."
          )
          FakeScheduler.new
        when :immediate
          FakeScheduler.new
        when :fiber
          Phronomy.configuration.logger&.warn(
            "[phronomy] runtime_backend: :fiber uses DeterministicScheduler in autorun mode. " \
            "This is an EXPERIMENTAL Fiber-based cooperative scheduler. " \
            "Wall-clock timer integration is available via SchedulerTimerAdapter (Issues #331, #337). " \
            "Not recommended for production use."
          )
          DeterministicScheduler.new(autorun: true)
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
      @task_registry = TaskRegistry.new
      @metrics = RuntimeMetrics.new
      @gate_registry = GateRegistry.new
      @pool_registry = PoolRegistry.new
      @timer_service = TimerService.new(scheduler)
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
      @gate_registry.get(name.to_sym)
    end

    # Drops the cached gate for +name+ so that the next call to {#gate} rebuilds
    # it from the current configuration.  Useful in tests.
    #
    # @param name [Symbol]
    # @return [void]
    # @api private
    def reset_gate(name)
      @gate_registry.reset(name.to_sym)
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
    # +non_yield_threshold_violation_count+.
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
            @metrics.increment_starvation
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
    def non_yield_threshold_violation_count
      @metrics.starvation_count
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
      @metrics.record_start(type)

      task = @scheduler.spawn(name: name, parent: Task.current) do
        run_start = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        @metrics.record_wait(run_start - spawn_at)
        begin
          result = block.call
          @metrics.record_end(type, :completed, run_start)
          result
        rescue CancellationError
          @metrics.record_end(type, :cancelled, run_start)
          raise
        rescue => e
          @metrics.record_end(type, :failed, run_start)
          raise e
        ensure
          current = Task.current
          @task_registry.deregister(current) if current
        end
      end
      @task_registry.register(task)
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
    # | `non_yield_threshold_violation_count` | cumulative count of tasks that ran past `blocking_detect_threshold_ms` without yielding |
    #
    # @return [Hash{Symbol => Numeric}]
    # @api private
    def task_snapshot
      @metrics.snapshot
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
      @pool_registry.default_pool(pool_size: pool_size, queue_size: queue_size)
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
      @pool_registry.named_pool(name, size: size, queue_size: queue_size)
    end

    # Returns the shared timer queue for this Runtime.
    #
    # When the scheduler is a {DeterministicScheduler} (e.g. the +:fiber+
    # runtime backend), returns a {SchedulerTimerAdapter} that integrates with
    # the scheduler's tick cycle instead of spawning a background OS thread.
    # This is the first concrete step of the TimerQueue scheduler-tick integration
    # described in ADR-010 (Issue #331).
    #
    # For all other schedulers, returns a {TimerQueue} backed by a single
    # background thread.
    #
    # All deadline-based cancellation should be registered here instead of
    # spawning one-off sleep threads.  Lazily created on first access.
    #
    # @return [TimerQueue, SchedulerTimerAdapter]
    # @api private
    def timer_queue
      @timer_service.timer_queue
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
      @task_registry.drain
      # Drain EventLoop events before stopping pools so that in-flight
      # Workflow / Agent FSM sessions can complete their final LLM calls.
      if Phronomy.configuration.event_loop
        Phronomy::EventLoop.instance.stop(drain: true)
      end
      @pool_registry.shutdown
      @timer_service.shutdown
    end

    private

    TASK_TYPE_PREFIXES = %w[agent tool workflow rag llm vector].freeze
    private_constant :TASK_TYPE_PREFIXES

    def _task_type(name)
      return :other if name.nil?

      prefix = TASK_TYPE_PREFIXES.find { |p| name.to_s.start_with?("#{p}-") }
      prefix ? prefix.to_sym : :other
    end
  end
end
