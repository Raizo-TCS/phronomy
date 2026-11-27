# frozen_string_literal: true

module Phronomy
  # Manages an original attempt, one reserved recovery lane and their observers.
  # The domain owner authorizes work, interprets evidence and grants release.
  # Methods ending in _locked participate in that owner's existing mutex;
  # submission, task methods and notifications always run outside the mutex.
  # @api private
  class RetainedAttempts
    def initialize(mutex:, on_worker_recorded: nil)
      @mutex = mutex
      @on_worker_recorded = on_worker_recorded
      @initial = new_slot(nil, nil)
      @active = nil
      @observers = []
    end

    # Views contain no mutable slot, completion record or observer collection.
    # Result and error payloads retain their domain's ownership; do not freeze them.
    def snapshot_locked(id)
      slot = slot_locked(id)
      return unless slot
      slot.slice(:id, :kind, :started, :rejection_confirmed, :admission_unknown)
        .merge(slot[:completion].snapshot_locked).freeze
    end

    def active_snapshot_locked
      snapshot_locked(@active[:id]) if @active
    end

    def quiescent_locked?
      @initial[:completion].snapshot_locked[:physical] &&
        (!@active || @active[:completion].snapshot_locked[:physical])
    end

    # Reservation does not submit work or authorize a domain retry.
    def reserve_locked(id, observer:, kind: nil)
      raise Phronomy::Error, "A retained recovery attempt already owns the lane" if @active
      raise ArgumentError, "A recovery attempt requires an identity" unless id
      @active = new_slot(id, kind)
      @active[:observers] << observer
      id
    end

    def join_locked(id, observer:)
      slot = slot_locked(id)
      return false unless slot
      slot[:observers] << observer
      true
    end

    def register(observer)
      @mutex.synchronize { @observers << observer }
      observer.on_complete do |_value, _error|
        @mutex.synchronize do
          @observers.delete(observer)
          @active&.fetch(:observers)&.delete(observer)
        end
      end
      observer
    end

    def observers
      @mutex.synchronize { @observers.dup.freeze }
    end

    def take_observers_locked(id)
      slot = slot_locked(id)
      slot ? slot[:observers].shift(slot[:observers].length) : []
    end

    # The owner decides when to detach the lane. Retirement never cancels work.
    def retire_locked(id)
      return [] unless id && @active && @active[:id].equal?(id)
      observers = @active[:observers]
      @active = nil
      observers
    end

    def retire(id)
      @mutex.synchronize { retire_locked(id) }
    end

    def worker_started_locked(id)
      slot = slot_locked(id)
      slot[:started] = true if slot
    end

    def submission_rejected_locked(id)
      slot = slot_locked(id)
      slot[:rejection_confirmed] = true if slot
    end

    def task_returned_locked(id, task)
      slot = slot_locked(id)
      slot[:completion].attach_locked(task) if slot
    end

    # Only positive admission evidence permits the caller to declare refusal.
    def submission_failed_locked(id, error, refused:)
      slot = slot_locked(id)
      return unless slot
      slot[:admission_unknown] = !refused
      slot[:completion].submission_failed_locked(error, physical: refused)
    end

    def record_worker_locked(id, result, error)
      slot = slot_locked(id)
      return false unless slot
      slot[:completion].record_worker_locked(result, error)
      # Optional diagnostic bookkeeping shares the fact's atomic update. The
      # hook must perform no I/O, invoke no tasks and make no domain transition.
      @on_worker_recorded&.call(id, result, error)
      true
    end

    def release_references_locked(id)
      slot_locked(id)&.fetch(:completion)&.release_references_locked
    end

    def release_task_locked(id)
      slot_locked(id)&.fetch(:completion)&.release_task_locked
    end

    def submit(id, submitter:, missing_handle_message:)
      slot = @mutex.synchronize { slot_locked(id) }
      refusal = lambda do |_error|
        @mutex.synchronize { submission_rejected_locked(id) if slot_locked(id).equal?(slot) }
      end
      task = Phronomy::Execution.submit_with_rejection_evidence(submitter,
        on_full: :raise, on_rejected: refusal) do
        @mutex.synchronize { worker_started_locked(id) }
        result = yield
        @mutex.synchronize { record_worker_locked(id, result, nil) }
        result
      rescue Exception => error # rubocop:disable Lint/RescueException
        @mutex.synchronize { record_worker_locked(id, nil, error) }
        raise
      end
      raise Phronomy::Error, missing_handle_message unless task
      @mutex.synchronize { task_returned_locked(id, task) }
      task
    rescue => error
      @mutex.synchronize do
        if slot && slot_locked(id).equal?(slot)
          refused = slot[:rejection_confirmed] && !slot[:started] && !slot[:completion].task
          submission_failed_locked(id, error, refused: refused)
        end
      end
      raise
    end

    def watch(id, &on_event)
      completion, task = @mutex.synchronize { completion_and_task_locked(id) }
      completion&.watch(task, &on_event)
    end

    def refresh(id)
      completion, task = @mutex.synchronize { completion_and_task_locked(id) }
      completion ? completion.refresh(task) : false
    end

    private

    def slot_locked(id)
      id.nil? ? @initial : (@active if @active && @active[:id].equal?(id))
    end

    def completion_and_task_locked(id)
      completion = slot_locked(id)&.fetch(:completion)
      [completion, completion&.task]
    end

    def new_slot(id, kind)
      {id: id, kind: kind, completion: AttemptCompletion.new(mutex: @mutex),
       started: false, observers: [], rejection_confirmed: false, admission_unknown: false}
    end
  end
end
