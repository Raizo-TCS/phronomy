# frozen_string_literal: true

require_relative "concurrency/worker_input_restricted"

require_relative "runtime/timer_queue"
require_relative "runtime/shutdown_result"
require_relative "runtime/timer_service"

module Phronomy
  class Runtime
    include Phronomy::Concurrency::WorkerInputRestricted

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

      def reset_default!(timeout: Phronomy::RuntimeSettings.current.event_loop_stop_grace_seconds)
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
      @shutdown_participants = {}
      @shutdown_participant_error = nil
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
      pool_size: Phronomy::RuntimeSettings.current.offload_pool_size,
      queue_size: Phronomy::RuntimeSettings.current.offload_queue_size
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

    # Lookup only; inspection must not create an EventLoop during shutdown.
    # @api private
    def __event_loop_if_initialized
      @lifecycle_mutex.synchronize { @event_loop }
    end

    # Shares one internal participant per key for this Runtime's lifetime.
    # begin_draining must be idempotent, nonblocking and must not call Runtime:
    # admission closes under the same lifecycle lock as registration.
    # wait_until_idle receives an absolute monotonic deadline and returns a Boolean.
    # Optional after_runtime_shutdown runs outside the lifecycle lock only after
    # all waits succeed, EventLoop stops, and pools/timer finish shutdown. It must
    # be idempotent, short, and perform no I/O. Exceptions mark cleanup incomplete.
    # This is a shutdown contract, not an application extension point.
    # @api private
    def __register_shutdown_participant(key:, participant:)
      unless participant.respond_to?(:begin_draining) && participant.respond_to?(:wait_until_idle)
        raise ArgumentError, "shutdown participant must implement begin_draining and wait_until_idle"
      end

      @lifecycle_mutex.synchronize do
        unless @state == :running
          raise Phronomy::RuntimeShutdownError,
            "Runtime is #{@state}; shutdown participants cannot be registered"
        end
        @shutdown_participants[key] ||= participant
      end
    end

    # Lookup only: never registers a participant or reopens its admission gate.
    # Retained participants remain available during and after shutdown.
    # @api private
    def __shutdown_participant(key:)
      @lifecycle_mutex.synchronize { @shutdown_participants[key] }
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
        begin_draining_participants
      end
    end

    def shutdown(
      timeout: Phronomy::RuntimeSettings.current.event_loop_stop_grace_seconds,
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
        loop_instance, participants = @lifecycle_mutex.synchronize do
          @state = :draining unless @state == :failed
          begin_draining_participants
          [@event_loop, @shutdown_participants.values]
        end
        loop_instance&.begin_draining

        participants_idle = wait_for_participants(participants, drain_deadline)
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
        participant_error = @lifecycle_mutex.synchronize { @shutdown_participant_error }
        cleanup_complete = participants_idle && participant_error.nil? &&
          loop_idle &&
          (!loop_instance || !loop_instance.thread_alive?) &&
          event_loop_status != :cancel_timeout &&
          (!loop_instance || loop_instance.__receiver_cleanup_complete?) &&
          subsystem_error.nil?

        cleanup_complete = finalize_participants(participants) if cleanup_complete
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

    # Called with the lifecycle lock held; participants only close their gates.
    def begin_draining_participants
      @shutdown_participants.each_value do |participant|
        participant.begin_draining
      rescue => error
        record_participant_failure(error)
      end
    end

    # All gates are already closed. Wait without holding the lifecycle lock and
    # give every participant the same deadline, even if an earlier wait fails.
    def wait_for_participants(participants, deadline)
      participants.map do |participant|
        participant.wait_until_idle(deadline) == true
      rescue => error
        @lifecycle_mutex.synchronize { record_participant_failure(error) }
        false
      end.all?
    end

    # Finalize every participant even if one fails. Earlier releases are not
    # rolled back, and a failure prevents replacement of the default Runtime.
    def finalize_participants(participants)
      participants.map do |participant|
        participant.after_runtime_shutdown if participant.respond_to?(:after_runtime_shutdown)
        true
      rescue => error
        @lifecycle_mutex.synchronize { record_participant_failure(error) }
        false
      end.all?
    end

    # Called with the lifecycle lock held. Failed hooks make cleanup uncertain.
    def record_participant_failure(error)
      @shutdown_participant_error ||= error
      @failure ||= error
      @state = :failed
    end

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
