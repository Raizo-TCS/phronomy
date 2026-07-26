# frozen_string_literal: true

require_relative "runtime/scheduler"
require_relative "runtime/thread_scheduler"
require_relative "runtime/fake_scheduler"
require_relative "runtime/deterministic_scheduler"
require_relative "runtime/timer_queue"
require_relative "runtime/scheduler_timer_adapter"
require_relative "runtime/task_registry"
require_relative "runtime/runtime_metrics"
require_relative "runtime/shutdown_result"
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
  #   expect(task.wait_result).to eq(42)
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
    @instance_mutex = Mutex.new

    class << self
      def instance
        instance_mutex.synchronize do
          @instance ||= build_default_runtime
        end
      end

      # Compatibility setter retained for existing tests.
      def instance=(runtime)
        replace_default_for_test(runtime)
      end

      # Test-only, non-creating access to the default Runtime.
      def default_if_initialized_for_test
        instance_mutex.synchronize { @instance }
      end

      # Test-only replacement. The caller owns both Runtime lifecycles.
      def replace_default_for_test(runtime)
        instance_mutex.synchronize do
          previous = @instance
          @instance = runtime
          previous
        end
      end

      # Test-only restoration of a previously captured Runtime.
      def restore_default_for_test(runtime)
        instance_mutex.synchronize { @instance = runtime }
      end

      def reset_default!(timeout: Phronomy.configuration.event_loop_stop_grace_seconds)
        runtime = instance_mutex.synchronize { @instance }
        return ShutdownResult.not_started unless runtime

        result = runtime.shutdown(timeout: timeout)
        unless result.cleanup_complete?
          raise Phronomy::RuntimeShutdownError,
            "Runtime cleanup is incomplete; default Runtime was retained"
        end

        instance_mutex.synchronize do
          @instance = nil if @instance.equal?(runtime)
        end
        result
      end

      # Does not create a Runtime or EventLoop.
      def in_event_loop_context?
        runtime = instance_mutex.synchronize { @instance }
        runtime&.event_loop_current? || false
      end

      private

      def instance_mutex
        @instance_mutex ||= Mutex.new
      end

      def build_default_runtime
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

    # Executes +block+ and returns +[result, elapsed_ms]+ where +elapsed_ms+
    # is the wall-clock duration in milliseconds (Integer, rounded).
    #
    # Isolates all direct references to +Process.clock_gettime+ /
    # +Process::CLOCK_MONOTONIC+ in one place so that callers stay at the
    # framework abstraction level.
    #
    # @yield block to time
    # @return [Array(Object, Integer)] +[block_return_value, elapsed_ms]+
    # @api private
    def self.measure_ms
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      [result, elapsed_ms]
    end

    # The scheduler backing this runtime instance.
    # @return [Scheduler]
    attr_reader :scheduler

    # @return [Symbol] current Runtime lifecycle state
    # @api private
    def state
      @lifecycle_mutex.synchronize { @state }
    end

    # @param scheduler [Scheduler] execution backend (default: {ThreadScheduler})
    # @api private
    def initialize(scheduler: ThreadScheduler.new)
      @scheduler = scheduler
      @event_loop_scheduler = ThreadScheduler.new
      @task_registry = TaskRegistry.new
      @metrics = RuntimeMetrics.new
      @timer_service = TimerService.new(scheduler)
      @pool_registry = Phronomy::Concurrency::PoolRegistry.new(
        timer_queue_provider: -> { @timer_service.timer_queue }
      )
      @lifecycle_mutex = Mutex.new
      @shutdown_mutex = Mutex.new
      @state = :running
      @event_loop = nil
      @failure = nil
      @shutdown_result = nil
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
      ensure_accepting_work!
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
      ensure_accepting_work!
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
    # @param pool_size  [Integer] worker thread count
    #   (default: {Phronomy::Configuration#blocking_io_pool_size}, currently 10)
    # @param queue_size [Integer] max pending operations
    #   (default: {Phronomy::Configuration#blocking_io_queue_size}, currently 100)
    # @return [BlockingAdapterPool]
    # @api private
    def blocking_io(pool_size: Phronomy.configuration.blocking_io_pool_size,
      queue_size: Phronomy.configuration.blocking_io_queue_size)
      ensure_accepting_work!
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
      ensure_accepting_work!
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
      ensure_accepting_work!
      @timer_service.timer_queue
    end

    # Returns the Runtime-owned EventLoop, creating it once on first use.
    # During draining an existing loop remains available, but an unused loop
    # is never created after shutdown begins.
    # @api private
    def event_loop
      @lifecycle_mutex.synchronize do
        case @state
        when :running
          @event_loop ||= EventLoop.new(runtime: self)
        when :draining
          return @event_loop if @event_loop

          raise Phronomy::RuntimeShutdownError,
            "EventLoop was not initialized before Runtime shutdown began"
        else
          raise Phronomy::RuntimeShutdownError,
            "Runtime is #{@state}; EventLoop is unavailable"
        end
      end
    end

    # Does not create an EventLoop.
    # @api private
    def event_loop_current?
      event_loop = @lifecycle_mutex.synchronize { @event_loop }
      event_loop&.current? || false
    end

    # Internal EventLoop service spawn. Always uses a real OS thread and is
    # deliberately excluded from the normal TaskRegistry drain.
    # @api private
    def __spawn_event_loop_service(&block)
      @event_loop_scheduler.spawn(name: "event-loop", parent: nil, &block)
    end

    # Called only for an unexpected dispatcher failure.
    # @api private
    def __event_loop_failed(error)
      @lifecycle_mutex.synchronize do
        return if @shutdown_result || @state == :terminated

        @failure ||= error
        @state = :failed
      end
    end

    # Synchronous, bounded Runtime shutdown. Must be invoked from an external
    # management thread, lifecycle hook, or test teardown—not a Phronomy Task.
    #
    # +timeout+ bounds TaskRegistry and EventLoop graceful shutdown. Existing
    # pool and timer shutdown contracts are unchanged by this proposal.
    # @return [Runtime::ShutdownResult]
    # @api public
    def shutdown(
      timeout: Phronomy.configuration.event_loop_stop_grace_seconds,
      cancel_grace: timeout
    )
      if Phronomy::Task.current
        raise Phronomy::RuntimeShutdownReentrancyError,
          "Runtime#shutdown must be called from an external management thread"
      end
      validate_timeout!(timeout, :timeout)
      validate_timeout!(cancel_grace, :cancel_grace)

      @shutdown_mutex.synchronize do
        return @shutdown_result if @shutdown_result

        deadline = monotonic_now + timeout
        event_loop = @lifecycle_mutex.synchronize do
          @state = :draining unless @state == :failed
          @event_loop
        end
        event_loop&.begin_draining

        task_status = drain_runtime_work(event_loop, deadline)

        @lifecycle_mutex.synchronize do
          @state = :stopping unless @state == :failed
        end

        event_loop_status = if event_loop
          event_loop.shutdown(deadline: deadline, cancel_grace: cancel_grace)
        else
          :not_started
        end

        subsystem_error = shutdown_pools_and_timer
        final_task_status = @task_registry.empty? ? :empty : task_status
        cleanup_complete = final_task_status == :empty &&
          (!event_loop || !event_loop.task_alive?) &&
          event_loop_status != :cancel_timeout &&
          subsystem_error.nil?

        failure = @lifecycle_mutex.synchronize { @failure } || subsystem_error
        runtime_outcome = if failure || event_loop_status == :failed
          :failed
        else
          :terminated
        end
        result = ShutdownResult.new(
          runtime_outcome: runtime_outcome,
          cleanup_status: cleanup_complete ? :complete : :incomplete,
          event_loop_status: event_loop_status,
          task_registry_status: final_task_status,
          error: failure
        )

        @lifecycle_mutex.synchronize do
          @state = cleanup_complete ? runtime_outcome : :failed
          @shutdown_result = result
        end
        result
      end
    end

    private

    def ensure_accepting_work!
      current_state = @lifecycle_mutex.synchronize { @state }
      return if %i[running draining].include?(current_state)

      raise Phronomy::RuntimeShutdownError,
        "Runtime is #{current_state}; new work is not accepted"
    end

    def drain_runtime_work(event_loop, deadline)
      loop do
        task_status = @task_registry.drain_until(deadline)
        return :timeout if task_status == :timeout

        event_loop_idle = !event_loop || event_loop.wait_until_idle(deadline)
        return :timeout unless event_loop_idle
        return :empty if @task_registry.empty?
      end
    end

    def shutdown_pools_and_timer
      error = nil
      begin
        @pool_registry.shutdown
      rescue => e
        error ||= e
      ensure
        begin
          @timer_service.shutdown
        rescue => e
          error ||= e
        end
      end
      error
    end

    def validate_timeout!(value, name)
      return if value.is_a?(Numeric) && value >= 0

      raise ArgumentError, "#{name} must be a non-negative Numeric"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    TASK_TYPE_PREFIXES = %w[agent tool workflow rag llm vector].freeze
    private_constant :TASK_TYPE_PREFIXES

    def _task_type(name)
      return :other if name.nil?

      prefix = TASK_TYPE_PREFIXES.find { |p| name.to_s.start_with?("#{p}-") }
      prefix ? prefix.to_sym : :other
    end
  end
end
