# frozen_string_literal: true

module Phronomy
  module Agent
    # Records one worker's facts independently of its logical task observation.
    # Readers and *_locked methods require the supplied owner's mutex. This lets
    # owners combine physical facts with their own custody decisions atomically.
    # Task methods and notifications always run outside that mutex.
    # @api private
    class PhysicalAttempt
      attr_reader :task, :physical, :logical, :result, :error, :watch_error, :physical_watch

      def initialize(mutex:)
        @mutex = mutex
        @task = @result = @error = @watch_error = nil
        @physical = @logical = @worker_recorded = @physical_watch = false
      end

      def attach_locked(task)
        @task = task
      end

      def record_worker_locked(result, error)
        @result, @error, @worker_recorded = result, error, true
      end

      # The owner supplies its admission conclusion; this record cannot infer it.
      def submission_failed_locked(error, physical:)
        @logical, @physical, @error = true, physical, error
      end

      def snapshot_locked
        {physical: @physical, logical: @logical, result: @result, error: @error,
         watch_error: @watch_error, physical_watch: @physical_watch}.freeze
      end

      # Release heavy references after the owner has finished its delivery.
      def clear_locked
        @task = @result = @error = @watch_error = nil
      end

      def watch(task)
        @mutex.synchronize { attach_locked(task) }
        physical = task.respond_to?(:on_physical_complete)
        if physical
          task.on_physical_complete do
            @mutex.synchronize { @physical = true }
            yield :physical
          end
          @mutex.synchronize { @physical_watch = true }
        end
        task.on_complete do |result, error|
          @mutex.synchronize { record_observation_locked(result, error, physical: !physical) }
          yield :logical
        end
      rescue => error
        @mutex.synchronize { @watch_error = error }
        raise
      end

      def refresh
        task = @mutex.synchronize { @task }
        return false unless task
        status, value, error = task.__snapshot
        physical = if task.respond_to?(:physical_complete?)
          task.physical_complete?
        else
          !task.respond_to?(:on_physical_complete) && status != :pending
        end
        @mutex.synchronize do
          @physical ||= physical
          record_observation_locked(value, error, physical: false) unless status == :pending
        end
        true
      end

      private

      def record_observation_locked(result, error, physical:)
        @logical = true
        @physical ||= physical
        @result, @error = result, error unless @worker_recorded
      end
    end
  end
end
