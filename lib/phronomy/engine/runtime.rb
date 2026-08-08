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
  class Runtime
    @instance_mutex = Mutex.new

    class << self
      def instance
        instance_mutex.synchronize do
          @instance ||= build_default_runtime
        end
      end

      def default_if_initialized_for_test
        instance_mutex.synchronize { @instance }
      end

      def replace_default_for_test(runtime)
        instance_mutex.synchronize do
          previous = @instance
          @instance = runtime
          previous
        end
      end

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
        when :thread
          ThreadScheduler.new
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
          raise Phronomy::ConfigurationError,
            "unknown runtime_backend: #{Phronomy.configuration.runtime_backend.inspect}"
        end
        new(scheduler: scheduler)
      end
    end

    def self.in_scheduler_context?
      !Task.current.nil?
    end

    def self.measure_ms
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      [result, elapsed_ms]
    end

    attr_reader :scheduler

    def state
      @lifecycle_mutex.synchronize { @state }
    end

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

    def non_yield_threshold_violation_count
      @metrics.starvation_count
    end

    def yield_if_needed(every: 1000)
      self.yield if (Task.increment_yield_counter! % every).zero?
    end

    def task_group(limit: Float::INFINITY, failure_policy: :fail_fast)
      ensure_accepting_work!
      TaskGroup.new(limit: limit, failure_policy: failure_policy, runtime: self)
    end

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
        rescue => error
          @metrics.record_end(type, :failed, run_start)
          raise error
        ensure
          current = Task.current
          @task_registry.deregister(current) if current
        end
      end
      @task_registry.register(task)
      task
    end

    def task_snapshot
      @metrics.snapshot
    end

    def blocking_io(
      pool_size: Phronomy.configuration.blocking_io_pool_size,
      queue_size: Phronomy.configuration.blocking_io_queue_size
    )
      ensure_accepting_work!
      @pool_registry.default_pool(pool_size: pool_size, queue_size: queue_size)
    end

    def pool(name, size: 10, queue_size: 100)
      ensure_accepting_work!
      @pool_registry.named_pool(name, size: size, queue_size: queue_size)
    end

    def timer_queue
      ensure_accepting_work!
      @timer_service.timer_queue
    end

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

    def event_loop_current?
      event_loop = @lifecycle_mutex.synchronize { @event_loop }
      event_loop&.current? || false
    end

    def __spawn_event_loop_service(&block)
      @event_loop_scheduler.spawn(name: "event-loop", parent: nil, &block)
    end

    def __event_loop_failed(error)
      @lifecycle_mutex.synchronize do
        return if @shutdown_result || @state == :terminated

        @failure ||= error
        @state = :failed
      end
    end

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
      rescue => caught
        error ||= caught
      ensure
        begin
          @timer_service.shutdown
        rescue => caught
          error ||= caught
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

      prefix = TASK_TYPE_PREFIXES.find { |candidate| name.to_s.start_with?("#{candidate}-") }
      prefix ? prefix.to_sym : :other
    end
  end
end
