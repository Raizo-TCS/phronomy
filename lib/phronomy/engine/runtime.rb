# frozen_string_literal: true

require_relative "runtime/timer_queue"
require_relative "runtime/shutdown_result"
require_relative "runtime/timer_service"
require_relative "runtime/agent_ownership_registry"

module Phronomy
  class Runtime
    @instance_mutex = Mutex.new

    class << self
      def instance
        instance_mutex.synchronize { @instance ||= new }
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
    end

    def initialize
      @timer_service = TimerService.new
      @pool_registry = Phronomy::Concurrency::PoolRegistry.new(
        timer_queue_provider: -> { timer_queue }
      )
      @multi_agent_admissions = Phronomy::MultiAgent::AdmissionRegistry.new
      @agent_ownership_registry = AgentOwnershipRegistry.new(runtime: self)
      @lifecycle_mutex = Mutex.new
      @shutdown_mutex = Mutex.new
      @state = :running
      @event_loop = nil
      @failure = nil
      @shutdown_result = nil
    end

    def state
      @lifecycle_mutex.synchronize { @state }
    end

    def offload(
      pool_size: Phronomy.configuration.offload_pool_size,
      queue_size: Phronomy.configuration.offload_queue_size
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
      timer = @timer_service.timer_queue
      event_loop
      timer
    end

    def __timer_queue
      @timer_service.timer_queue
    end

    # Returns only an immutable process-local routing/ownership view. Mutable
    # execution state remains inside EventLoop and is never exposed to callers.
    # @api private
    def __agent_execution_owner(execution_id)
      loop_instance = @lifecycle_mutex.synchronize { @event_loop }
      loop_instance&.agent_execution_owner(execution_id)
    end

    # @api private
    def __create_agent(agent_id, expected_class:, &block)
      @agent_ownership_registry.create(agent_id, expected_class: expected_class, &block)
    end

    # @api private
    def __load_agent(agent_id, expected_class:, &block)
      @agent_ownership_registry.load(agent_id, expected_class: expected_class, &block)
    end

    # @api private
    def __get_agent(agent_id, expected_class:)
      @agent_ownership_registry.get(agent_id, expected_class: expected_class)
    end

    # @api private
    def __agent_owned?(agent)
      @agent_ownership_registry.owned?(agent)
    end

    # @api private
    def __begin_agent_purge(agent)
      @agent_ownership_registry.begin_purge(agent)
    end

    # @api private
    def __complete_agent_purge(agent, token)
      @agent_ownership_registry.complete_purge(agent, token)
    end

    # @api private
    def __abort_agent_purge(agent, token)
      @agent_ownership_registry.abort_purge(agent, token)
    end

    # @api private
    def __leave_agent_purge_uncertain(agent, token)
      @agent_ownership_registry.leave_purge_uncertain(agent, token)
    end

    # @api private
    def __agent_execution_admitted?(agent_id)
      loop_instance = @lifecycle_mutex.synchronize { @event_loop }
      loop_instance&.agent_execution_admitted?(agent_id) || false
    end

    # @api private
    def __admit_multi_agent(coordinator)
      current_state = @lifecycle_mutex.synchronize { @state }
      unless current_state == :running
        raise Phronomy::RuntimeShutdownError,
          "Runtime is #{current_state}; new Multi-Agent turns are not accepted"
      end
      @multi_agent_admissions.admit!(coordinator)
    end

    # @api private
    def __release_multi_agent(coordinator)
      @multi_agent_admissions.release!(coordinator)
    end

    def event_loop
      @lifecycle_mutex.synchronize do
        case @state
        when :running
          unless @event_loop
            @event_loop = EventLoop.new(runtime: self)
            @timer_service.wake_with { @event_loop&.wake }
          end
          @event_loop
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
      loop_instance = @lifecycle_mutex.synchronize { @event_loop }
      loop_instance&.current? || false
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
      if event_loop_current?
        raise Phronomy::RuntimeShutdownReentrancyError,
          "Runtime#shutdown must be called from an external management thread"
      end
      validate_timeout!(timeout, :timeout)
      validate_timeout!(cancel_grace, :cancel_grace)

      @shutdown_mutex.synchronize do
        return @shutdown_result if @shutdown_result

        drain_deadline = monotonic_now + timeout
        loop_instance = @lifecycle_mutex.synchronize do
          @state = :draining unless @state == :failed
          @event_loop
        end
        loop_instance&.begin_draining
        @agent_ownership_registry.begin_draining

        admission_idle = @multi_agent_admissions.wait_until_idle(drain_deadline)
        agent_ownership_stable = @agent_ownership_registry.wait_until_stable(drain_deadline)
        loop_idle = !loop_instance || loop_instance.wait_until_idle(drain_deadline)

        @lifecycle_mutex.synchronize do
          @state = :stopping unless @state == :failed
        end

        stop_deadline = monotonic_now + [cancel_grace.to_f, 0.2].max
        event_loop_status = if loop_instance
          loop_instance.stop_and_join(deadline: stop_deadline)
        else
          :not_started
        end

        subsystem_error = shutdown_pools_and_timer
        cleanup_complete = admission_idle && agent_ownership_stable && loop_idle &&
          (!loop_instance || !loop_instance.thread_alive?) &&
          event_loop_status != :cancel_timeout &&
          subsystem_error.nil?

        failure = @lifecycle_mutex.synchronize { @failure } || subsystem_error
        runtime_outcome = if failure || event_loop_status == :failed
          :failed
        else
          :terminated
        end

        @agent_ownership_registry.shutdown! if cleanup_complete

        result = ShutdownResult.new(
          runtime_outcome: runtime_outcome,
          cleanup_status: cleanup_complete ? :complete : :incomplete,
          event_loop_status: event_loop_status,
          task_registry_status: :empty,
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
  end
end
