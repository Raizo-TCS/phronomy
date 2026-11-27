# frozen_string_literal: true

require "securerandom"

module Phronomy
  # Workflow-owned evidence, observation and application for one terminal save.
  # Only evidence mailboxes and observer lists are shared with worker callbacks.
  # Domain application and admission release stay on the captured serial owner.
  # @api private
  class WorkflowTerminalOperation
    Observe = Data.define(:operation, :observer)
    Ready = Data.define(:operation, :attempt_id)

    attr_reader :workflow_instance_id, :recovery_id, :owner_token,
      :fsm_session_id, :recovery

    def initialize(runner_identity:, environment:, registry:, execution:, command:,
      terminal_type:, event_sink:, context_class:)
      @runner_identity = runner_identity
      @environment = environment
      @registry = registry
      @command = command
      @workflow_instance_id = execution.workflow_instance_id.to_s.freeze
      @owner_token = execution.owner_token
      @fsm_session_id = registry.workflow_admission_fsm_session_id(@workflow_instance_id)
      @terminal_type = terminal_type
      @event_sink = event_sink
      @context_class = context_class
      @snapshot = command.snapshot
      @original_observer = execution.result_task
      @mutex = Mutex.new
      @attempts = Phronomy::RetainedAttempts.new(mutex: @mutex)
      @original_error = nil
      @last_error = nil
      @uncertain = false
      @adopted = false
      @initial_delivered = false
      @session_decision = nil
      @confirmation = nil
      @application_state = :pending
      @ownership_state = :retained
      @recovery_id = SecureRandom.uuid.freeze
      @recovery = WorkflowTerminalRecovery.send(:new, self)
    end

    def belongs_to?(identity)
      @runner_identity.equal?(identity)
    end

    def pending?
      @mutex.synchronize { @uncertain && @ownership_state == :retained }
    end

    def start
      @registry.retain_terminal_operation(self)
      task = submit_worker(nil) do
        WorkflowTerminalPersistence.save(@command, on_error: method(:remember_save_error))
      end
      watch(nil)
      self
    rescue => error
      refused = @mutex.synchronize do
        initial = @attempts.snapshot_locked(nil)
        initial[:rejection_confirmed] && !initial[:started]
      end
      if task || !refused
        # An absent handle is not refusal evidence. Keep the command and original
        # owner when admission is unknown, just as for callback binding failure.
        reject_initial_delivery(error)
        return self
      end
      # Only synchronous executor refusal proves that this save cannot run.
      # Workflow preserves its ordinary known-failure release policy in that case.
      @mutex.synchronize do
        @attempts.submission_failed_locked(nil, error, refused: true)
        @session_decision = :known_failure
        @application_state = :applied
      end
      raise
    end

    def remember_save_error(error)
      @mutex.synchronize { @original_error ||= error }
    end

    # Called by the Workflow terminal policy, on the owner, before translating
    # the result into a generic FSM terminal decision.
    def accept_terminal_result(result)
      @mutex.synchronize do
        unless @initial_delivered && result.equal?(@delivered_result)
          raise Phronomy::Error, "stale Workflow terminal persistence result"
        end
        @session_decision = result.outcome
      end
    end

    def adopt_retirement(retirement)
      return false unless retirement.fsm_session_id.to_s == @fsm_session_id.to_s
      @mutex.synchronize do
        @retirement = retirement
        @uncertain = true
        @last_error ||= retirement.error
      end
      true
    end

    def confirm_retirement(retirement)
      @mutex.synchronize do
        unless @retirement.equal?(retirement)
          raise Phronomy::Error, "Workflow completion custody does not match its accepted retirement"
        end
        @adopted = true
      end
    end

    def normal_finalization?
      @mutex.synchronize do
        !@uncertain && @attempts.snapshot_locked(nil)[:physical] && %i[success known_failure].include?(@session_decision)
      end
    end

    def apply_normal_finalization
      @mutex.synchronize { @application_state = :applied }
    end

    def release_permitted?
      @mutex.synchronize do
        @application_state == :applied && (!@uncertain || @adopted) && @attempts.quiescent_locked?
      end
    end

    def released
      @mutex.synchronize do
        @ownership_state = :released
        @original_observer = nil
        @environment = @registry = @command = @event_sink = nil
        @attempts.release_task_locked(nil)
      end
    end

    # Observation-only settlement. Never complete the Engine source as an
    # ordinary failure here: its finalizer may release domain ownership.
    def fail_original(error = nil)
      observer, failure = @mutex.synchronize do
        next [nil, nil] if @ownership_state == :released
        @uncertain = true
        @last_error = error if error
        [@original_observer, diagnostic_locked(@last_error || @original_error)]
      end
      observer&.fail(failure)
      failure
    end

    def observe
      observer = TaskResult.deferred(name: "workflow-reconcile:#{@recovery_id}")
      @attempts.register(observer)
      registry, released = @mutex.synchronize { [@registry, @ownership_state == :released] }
      if released
        observer.complete(build_result)
      elsif !registry || !registry.post(Observe.new(operation: self, observer: observer),
        completion: delivery_observer(observer))
        observer.complete(unavailable_result(Phronomy::RuntimeShutdownError.new("Original Workflow owner is unavailable")))
      end
      observer
    rescue => error
      observer.complete(unavailable_result(error))
      observer
    end

    def shutdown(error)
      fail_original(error)
      observers = @attempts.observers
      observers.each { |observer| observer.complete(unavailable_result(error)) }
    end

    def deliver(message)
      case message
      when Observe then observe_on_owner(message.observer)
      when Ready
        message.attempt_id ? finish_attempt(message.attempt_id) : deliver_initial_result
      else
        raise Phronomy::Error, "unsupported Workflow recovery message"
      end
    end

    private

    def delivery_observer(observer)
      TaskResult.deferred(name: "workflow-reconcile-delivery:#{@recovery_id}").tap do |delivery|
        delivery.on_complete do |_value, error|
          observer.complete(unavailable_result(error)) if error
        end
      end
    end

    def submit_worker(id, &work)
      @attempts.submit(id, submitter: @environment,
        missing_handle_message: "Workflow submission returned no task", &work)
    end

    def watch(id)
      @attempts.watch(id) { signal(id) }
    end

    def signal(id)
      registry = @mutex.synchronize { @registry }
      return unless registry
      return if registry.post(Ready.new(operation: self, attempt_id: id))
      delivery_failed(id, Phronomy::RuntimeShutdownError.new("Workflow owner rejected terminal evidence"))
    rescue => error
      delivery_failed(id, error)
    end

    def delivery_failed(id, error)
      if id
        observers = @mutex.synchronize do
          @attempts.take_observers_locked(id)
        end
        result = unavailable_result(error)
        observers.each { |observer| observer.complete(result) }
      else
        fail_original(error)
      end
    end

    def persistence_result(slot)
      return slot[:result] if slot[:physical] && slot[:result]
      if slot[:physical] && !slot[:started] && slot[:error]
        return WorkflowTerminalPersistence::Result.new(
          outcome: :known_failure, revision: nil, error: slot[:error]
        )
      end
      WorkflowTerminalPersistence::Result.new(outcome: :outcome_unknown,
        revision: nil, error: slot[:error] || Phronomy::Error.new("Workflow persistence is not physically complete"))
    end

    def retain_classification(result)
      @mutex.synchronize do
        if %i[success known_failure].include?(result.outcome)
          @confirmation ||= result
        else
          @uncertain = true
          @last_error = result.error
        end
      end
      result
    end

    def deliver_initial_result
      result, sink = @mutex.synchronize do
        return unless @attempts.snapshot_locked(nil)[:logical]
        return if @initial_delivered || @ownership_state == :released
        result = persistence_result(@attempts.snapshot_locked(nil))
        if @uncertain
          result = WorkflowTerminalPersistence::Result.new(
            outcome: :outcome_unknown, revision: nil, error: @last_error || result.error
          )
        end
        @initial_delivered = true
        @delivered_result = result
        [result, @event_sink]
      end
      retain_classification(result)
      return if sink.post(:workflow_terminal_persistence_result, result)
      reject_initial_delivery(Phronomy::Error.new("Workflow session rejected terminal evidence"))
    rescue => error
      reject_initial_delivery(error)
    end

    def reject_initial_delivery(error)
      fail_original(error)
      @environment&.retire_session(fsm_session_id: @fsm_session_id, error: error)
    rescue => retirement_error
      fail_original(retirement_error)
    end

    def observe_on_owner(observer)
      @attempts.refresh(nil)
      released, adopted, physical, active = @mutex.synchronize do
        [@ownership_state == :released, @adopted, @attempts.snapshot_locked(nil)[:physical], @attempts.active_snapshot_locked]
      end
      return observer.complete(build_result) if released
      unless @registry.owns_terminal_operation?(self)
        return observer.complete(unavailable_result(Phronomy::Error.new("Workflow recovery owner no longer matches")))
      end
      unless adopted
        @environment.retire_session(fsm_session_id: @fsm_session_id,
          error: diagnostic(@last_error || @original_error))
        return observer.complete(unavailable_result(Phronomy::Error.new("Workflow retirement custody is not yet accepted")))
      end
      unless physical
        return observer.complete(unavailable_result(Phronomy::Error.new("Original Workflow save has no physical completion proof")))
      end
      return observe_active_attempt(observer, active) if active

      # A late physical worker result remains useful even when its logical
      # TaskResult was abandoned. It is evidence, never a replayable write.
      save_result = @mutex.synchronize { persistence_result(@attempts.snapshot_locked(nil)) }
      retain_classification(save_result) unless @confirmation
      if @confirmation
        return observer.complete(apply_confirmation)
      end

      begin_reconciliation(observer)
    rescue => error
      observer.complete(unavailable_result(error))
    end

    def observe_active_attempt(observer, active)
      @attempts.refresh(active[:id])
      unknown, error, watch_error = @mutex.synchronize do
        active = @attempts.snapshot_locked(active[:id])
        [active[:admission_unknown], active[:error],
          (active[:watch_error] if !active[:physical_watch] && !active[:physical])]
      end
      if unknown
        return observer.complete(unavailable_result(error))
      end
      return observer.complete(unavailable_result(watch_error)) if watch_error
      @mutex.synchronize { @attempts.join_locked(active[:id], observer: observer) }
      finish_attempt(active[:id])
      nil
    end

    def begin_reconciliation(observer)
      id = Object.new.freeze
      @mutex.synchronize do
        @attempts.reserve_locked(id, observer: observer)
      end
      task = submit_worker(id) do
        WorkflowTerminalPersistence.reconcile(@command, @original_error || @last_error)
      end
      watch(id)
    rescue => error
      if task
        # An admitted read still owns its physical lane even when callback
        # registration fails. Another explicit observation may inspect it.
        delivery_failed(id, error)
        return
      end
      observers = @mutex.synchronize do
        active = @attempts.active_snapshot_locked
        if defined?(id) && id && active && active[:id].equal?(id)
          values = @attempts.take_observers_locked(id)
          # Unknown admission keeps the attempt even after all observers settle.
          # A late worker result alone cannot prove physical executor completion.
          @attempts.retire_locked(id) unless active[:admission_unknown]
          values
        else
          [observer]
        end
      end
      result = unavailable_result(error)
      observers.each { |item| item.complete(result) }
    end

    def finish_attempt(id)
      @attempts.refresh(id)
      result, error = @mutex.synchronize do
        slot = @attempts.snapshot_locked(id)
        return unless slot && slot[:physical] && slot[:logical]
        [slot[:result], slot[:error]]
      end
      if error && !error.is_a?(StandardError)
        observers = @attempts.retire(id)
        observers.each { |observer| observer.fail(error) }
        return
      end
      retain_classification(result) if result
      observation = if @confirmation
        apply_confirmation
      elsif error
        unavailable_result(error)
      else
        build_result(outcome: result&.error.is_a?(Phronomy::Persistence::StateConflictError) ? :unresolved : :unavailable,
          error: diagnostic(result&.error))
      end
      @attempts.retire(id).each_with_index do |observer, index|
        # Sharing a physical read does not share the mutable returned context.
        value = if index.zero?
          observation
        else
          build_result(outcome: observation.outcome, error: observation.error,
            materialize: observation.application_state == :applied)
        end
        observer.complete(value)
      end
    end

    def apply_confirmation
      # Reconstruct before release: a constructor failure leaves application
      # pending while preserving the independently confirmed durable fact.
      context = materialize if @confirmation.outcome == :success
      @mutex.synchronize { @application_state = :applied }
      unless @registry.release_workflow(@workflow_instance_id, owner_token: @owner_token)
        return build_result(error: diagnostic(Phronomy::Error.new("Workflow owner could not be released")))
      end
      build_result(context: context)
    rescue => error
      build_result(error: diagnostic(error))
    end

    def materialize
      fields = duplicate_value(@snapshot.fetch(:fields))
      @context_class.new(**fields).set_graph_metadata(
        workflow_instance_id: @workflow_instance_id,
        phase: @snapshot.fetch(:phase).to_sym
      )
    end

    def duplicate_value(value)
      case value
      when Hash then value.to_h { |key, child| [key, duplicate_value(child)] }
      when Array then value.map { |child| duplicate_value(child) }
      when String then value.dup
      else value
      end
    end

    def unavailable_result(error)
      build_result(outcome: :unavailable, error: diagnostic(error), materialize: false)
    end

    def build_result(outcome: nil, context: nil, error: nil, materialize: true)
      confirmation, applied, ownership = @mutex.synchronize do
        [@confirmation, @application_state, @ownership_state]
      end
      if confirmation
        outcome = (confirmation.outcome == :success) ? :confirmed_post : :confirmed_pre
        error ||= confirmation.error if outcome == :confirmed_pre
        context ||= self.materialize if materialize && outcome == :confirmed_post && !error
      end
      WorkflowTerminalRecoveryResult.new(recovery: @recovery,
        outcome: outcome || :unavailable, application_state: applied,
        ownership_state: ownership, revision: confirmation&.revision,
        context: context, error: error)
    rescue => materialization_error
      WorkflowTerminalRecoveryResult.new(recovery: @recovery,
        outcome: outcome || :unavailable, application_state: applied,
        ownership_state: ownership, revision: confirmation&.revision,
        context: nil, error: diagnostic(materialization_error))
    end

    def diagnostic(error)
      @mutex.synchronize { diagnostic_locked(error) }
    end

    def diagnostic_locked(error)
      return error if error && !error.is_a?(StandardError)
      return error if error.is_a?(WorkflowTerminalRecoveryError) && error.recovery.equal?(@recovery)
      WorkflowTerminalRecoveryError.new(recovery: @recovery,
        error: error || Phronomy::Error.new("Workflow terminal outcome requires reconciliation"),
        original_error: @original_error || error)
    end
  end
end
