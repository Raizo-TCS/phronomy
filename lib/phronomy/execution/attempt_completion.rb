# frozen_string_literal: true

module Phronomy
  # Records one worker's facts independently of its logical task observation.
  # Readers and *_locked methods require the supplied owner's mutex. This lets
  # owners combine physical facts with their own custody decisions atomically.
  # Task methods and notifications always run outside that mutex.
  # @api private
  class AttemptCompletion
    attr_reader :task

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

    def release_task_locked
      @task = nil
    end

    # Release heavy references after the owner has finished its delivery.
    def release_references_locked
      @task = @result = @error = @watch_error = nil
    end

    # The handle was attached before submission returned. Registering callbacks
    # must not attach it again or acquire the owner mutex around task methods.
    def watch(task)
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

    # The caller captures this record and its handle under one owner lock.
    # Read the task outside that lock, then merge with the latest worker facts.
    def refresh(task)
      return false unless task
      status, value, error = task.__snapshot
      physical = if task.respond_to?(:physical_complete?)
        task.physical_complete?
      else
        !task.respond_to?(:on_physical_complete) && status != :pending
      end
      @mutex.synchronize do
        return false unless @task.equal?(task)
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
