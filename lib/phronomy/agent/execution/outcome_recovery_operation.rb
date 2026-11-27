# frozen_string_literal: true

require "securerandom"
require "weakref"

module Phronomy
  module Agent
    # Owns one installed Agent's captured outcome save and recovery observations.
    # Workers publish facts into mailboxes; only the captured EventLoop may apply
    # them. A closed observer never relinquishes the accepted Agent execution.
    # @api private
    class OutcomeRecoveryOperation
      Observe = Data.define(:operation, :observer, :kind)
      Ready = Data.define(:operation, :attempt_id)

      attr_reader :agent, :coordinator, :environment, :agent_id, :execution_id, :fsm_session_id,
        :expected_execution_revision, :recovery_id, :recovery, :command, :delivery, :live_execution_before

      def initialize(agent:, coordinator:, environment:, command:, delivery:, committer:)
        @agent = agent
        @agent_reference = WeakRef.new(agent)
        @coordinator, @environment, @registry = coordinator, environment, environment.registry
        @persistence, @committer = agent.persistence, committer
        @command, @delivery = command, delivery
        @agent_id, @execution_id = agent.agent_id.to_s.freeze, command.execution_id
        # Suspension adds the completed Tool batch to the durable command. Its
        # exact local pre-state is the still-installed execution, before staging.
        @live_execution_before = @registry.agent_execution_state(@execution_id)&.execution
        @fsm_session_id, @expected_execution_revision = command.fsm_session_id, command.expected_execution_revision
        @recovery_id = SecureRandom.uuid.freeze
        @recovery = recovery_class.send(:new, self)
        @mutex = Mutex.new
        @save = new_slot(nil, :save)
        @attempt = nil
        @observers = []
        @original_waiters = [delivery.result_task]
        @evidence = @prepared_input = @intended = @confirmation = @execution_observation = nil
        @saved_outcome = @approval_request = @suspension_task = nil
        @original_error = @last_error = nil
        @uncertain = @initial_delivered = false
        @submission_state = :unknown
        @application_state, @ownership_state = :pending, :retained
      end

      def recovery_kind = :outcome

      def captured_cancellation_requested?
        @mutex.synchronize do
          @evidence&.after&.fetch(0)&.fetch(4) == true ||
            @intended&.execution&.metadata&.fetch("cancellation_requested", false) == true
        end
      end

      # A recovered wait cannot bind cancellation to its already-closed caller.
      # This private task follows the still-owned logical execution instead.
      def suspension_task
        @mutex.synchronize do
          @suspension_task ||= Phronomy::TaskResult.deferred(name: "recovered-approval-wait:#{recovery_id}")
        end
      end

      def belongs_to?(candidate)
        @agent_reference.__getobj__.equal?(candidate)
      rescue WeakRef::RefError
        false
      end

      def pending?
        @mutex.synchronize { @uncertain && @ownership_state == :retained }
      end

      def applied?
        @mutex.synchronize { @application_state == :applied }
      end

      def released?
        @mutex.synchronize { @ownership_state == :released }
      end

      def ordinary_delivery?
        @mutex.synchronize { !@uncertain }
      end

      def application_applied!
        @mutex.synchronize { @application_state = :applied }
      end

      def release_permitted?
        @mutex.synchronize do
          @application_state == :applied && @save[:completion].physical &&
            (!@attempt || @attempt[:completion].physical)
        end
      end

      def released
        @mutex.synchronize do
          @ownership_state = :released
          @agent = @coordinator = @environment = @registry = @persistence = @committer = nil
          @command = @delivery = @intended = @evidence = @prepared_input = @suspension_task = @live_execution_before = nil
          @save[:completion].clear_locked
          @original_waiters = []
          @original_error = @last_error = nil
        end
      end

      def start
        @registry.retain_terminal_operation(self)
        task = submit_terminal_worker(nil)
        watch(task, nil)
        self
      rescue => error
        if task
          mark_uncertain_on_owner(error)
        else
          @mutex.synchronize do
            @save[:completion].submission_failed_locked(error, physical: @submission_state == :not_admitted)
          end
          signal(nil)
        end
        self
      end

      def observe(kind = :reconcile)
        raise ArgumentError, "unsupported Agent #{recovery_kind} recovery operation" unless %i[reconcile retry submission].include?(kind)
        observer = Phronomy::TaskResult.deferred(name: "agent-#{recovery_kind}-#{kind}:#{@recovery_id}")
        @mutex.synchronize { @observers << observer }
        observer.on_complete do |_value, _error|
          @mutex.synchronize do
            @observers.delete(observer)
            @attempt&.fetch(:observers)&.delete(observer)
          end
        end
        registry, released = @mutex.synchronize { [@registry, @ownership_state == :released] }
        if released
          observer.complete(build_result)
        elsif !registry || !registry.post(Observe.new(operation: self, observer: observer, kind: kind),
          completion: delivery_observer(observer))
          observer.complete(unavailable_result(Phronomy::RuntimeShutdownError.new("Original Agent owner is unavailable")))
        end
        observer
      rescue => error
        observer&.complete(unavailable_result(error))
        observer || raise
      end

      def shutdown(error)
        failure = fail_original(error)
        observers = @mutex.synchronize { @observers.dup }
        observers.each { |observer| observer.complete(unavailable_result(error)) }
        failure
      end

      def deliver(message)
        case message
        when Observe then observe_on_owner(message.observer, message.kind)
        when Ready
          message.attempt_id ? finish_attempt(message.attempt_id) : deliver_initial
        else
          raise Phronomy::Error, "unsupported Agent #{recovery_kind} recovery message"
        end
      end

      # Safe outside EventLoop: only the original observation is settled here.
      # Registry ownership and live execution state remain untouched.
      def fail_original(error)
        task, failure = @mutex.synchronize do
          @uncertain = true
          @last_error = error
          @original_error ||= error
          [@delivery&.result_task, diagnostic_locked(error)]
        end
        task&.fail(failure)
        acknowledge_original_if_quiet
        failure
      end

      def retain_original_waiters(waiters)
        @mutex.synchronize { @original_waiters |= waiters }
        acknowledge_original_if_quiet
      end

      private

      def acknowledge_original_if_quiet
        waiters = @mutex.synchronize { (@uncertain && @save[:completion].physical) ? @original_waiters.dup : [] }
        waiters.each { |task| task.finish_operation! if task.respond_to?(:finish_operation!) }
      end

      def new_slot(id, kind)
        {id: id, kind: kind, completion: PhysicalAttempt.new(mutex: @mutex),
         started: false, observers: [], rejection_confirmed: false, admission_unknown: false}
      end

      def slot_for(id)
        id.nil? ? @save : (@attempt if @attempt && @attempt[:id].equal?(id))
      end

      # The executor's positive refusal callback is the admission evidence.
      # Exception class, absent handle and a not-yet-started block are not proof.
      # Consume a previous refusal before asking for a new execution right.
      def submit_terminal_worker(id)
        slot = @mutex.synchronize do
          @submission_state = :unknown
          slot_for(id)
        end
        refusal = lambda do |_error|
          @mutex.synchronize do
            slot[:rejection_confirmed] = true if slot_for(id).equal?(slot)
          end
        end
        task = Phronomy::Execution.submit_with_rejection_evidence(@environment, on_full: :raise, on_rejected: refusal) do
          @mutex.synchronize do
            @submission_state = :admitted
            slot[:started] = true
          end
          result = @committer.commit_outcome(@command,
            on_evidence: method(:capture_evidence), on_outcome: method(:capture_outcome),
            on_prepared: method(:capture_prepared_input))
          capture_worker(id, result, nil)
          result
        rescue Exception => error # rubocop:disable Lint/RescueException
          capture_worker(id, nil, error)
          raise
        end
        # An admitted queued task consumes authority even before its block starts.
        @mutex.synchronize do
          @submission_state = :admitted
          slot[:completion].attach_locked(task)
        end
        task
      rescue => error
        @mutex.synchronize do
          if slot && slot_for(id).equal?(slot)
            proven_refusal = slot[:rejection_confirmed] && !slot[:started] && @submission_state != :admitted
            @submission_state = :not_admitted if proven_refusal
            slot[:admission_unknown] = !proven_refusal
            slot[:completion].submission_failed_locked(error, physical: proven_refusal)
          end
        end
        raise
      end

      def capture_evidence(value)
        @mutex.synchronize { @evidence = value }
      end

      def capture_prepared_input(value)
        @mutex.synchronize do
          if @prepared_input && !@prepared_input.equal?(value)
            raise Phronomy::Error, "Agent outcome cannot replace its complete captured proposal"
          end
          @prepared_input = value
          @intended = value.values.fetch(:result)
        end
      end

      # Readback and captured-write retry own the same physical lane as first
      # submission. A lost handle cannot establish that their work was refused.
      # This fact belongs to the attempt; it does not change submission_state,
      # which describes the original terminal worker's admission.
      def submit_recovery_worker(id, &work)
        slot = @mutex.synchronize { slot_for(id) }
        refusal = lambda do |_error|
          @mutex.synchronize do
            slot[:rejection_confirmed] = true if slot_for(id).equal?(slot)
          end
        end
        task = Phronomy::Execution.submit_with_rejection_evidence(@environment, on_full: :raise, on_rejected: refusal) do
          @mutex.synchronize { slot[:started] = true }
          work.call
        end
        raise Phronomy::Error, "Agent #{recovery_kind} recovery submission returned no task handle" unless task
        @mutex.synchronize { slot[:completion].attach_locked(task) }
        task
      rescue => error
        @mutex.synchronize do
          if slot && slot_for(id).equal?(slot)
            proven_refusal = slot[:rejection_confirmed] && !slot[:started] && !slot[:completion].task
            slot[:admission_unknown] = !proven_refusal
            slot[:completion].submission_failed_locked(error, physical: proven_refusal)
          end
        end
        raise
      end

      def capture_outcome(value)
        @mutex.synchronize { @intended = value }
      end

      def capture_worker(id, result, error)
        @mutex.synchronize do
          slot = slot_for(id)
          return unless slot
          slot[:completion].record_worker_locked(result, error)
          @original_error ||= error if id.nil?
        end
      end

      def watch(task, id)
        completion = @mutex.synchronize { slot_for(id).fetch(:completion) }
        completion.watch(task) do |event|
          acknowledge_original_if_quiet if id.nil? && event == :physical
          signal(id)
        end
      end

      def refresh_slot(id)
        completion = @mutex.synchronize { slot_for(id)&.fetch(:completion) }
        acknowledge_original_if_quiet if completion&.refresh && id.nil?
      end

      def snapshot_slot_locked(slot)
        slot&.merge(slot.fetch(:completion).snapshot_locked)
      end

      def signal(id)
        registry = @mutex.synchronize { @registry }
        return unless registry
        return if registry.post(Ready.new(operation: self, attempt_id: id))
        delivery_failed(id, Phronomy::RuntimeShutdownError.new("Agent owner rejected terminal evidence"))
      rescue => error
        delivery_failed(id, error)
      end

      def delivery_failed(id, error)
        return fail_original(error) unless id
        observers = @mutex.synchronize do
          slot = slot_for(id)
          slot ? slot[:observers].shift(slot[:observers].length) : []
        end
        observers.each { |observer| observer.complete(unavailable_result(error)) }
      end

      def delivery_observer(observer)
        Phronomy::TaskResult.deferred(name: "agent-#{recovery_kind}-delivery:#{@recovery_id}").tap do |delivery|
          delivery.on_complete do |_value, error|
            observer.complete(unavailable_result(error)) if error
          end
        end
      end

      def deliver_initial
        refresh_slot(nil)
        slot, uncertain = @mutex.synchronize { [snapshot_slot_locked(@save), @uncertain] }
        return unless slot[:logical]
        return if @mutex.synchronize { @initial_delivered || @ownership_state == :released }
        return if !slot[:physical] && !slot[:error] && !uncertain
        if slot[:error] || uncertain
          error = slot[:error] || @last_error || Phronomy::Error.new("Agent #{recovery_kind} save requires explicit recovery")
          mark_uncertain_on_owner(error)
          @mutex.synchronize { @initial_delivered = true }
          return
        end
        @mutex.synchronize { @initial_delivered = true }
        remember_post(slot[:result])
        apply_confirmation
      rescue => error
        mark_uncertain_on_owner(error)
      end

      def mark_uncertain_on_owner(error)
        failure = fail_original(error)
        coordinator = @mutex.synchronize { @coordinator }
        coordinator&.send(:terminal_recovery_failed_on_event_loop, self, failure)
        failure
      end

      def observe_on_owner(observer, kind)
        return if observer.done?
        refresh_slot(nil)
        registry, released, physical, active = @mutex.synchronize do
          [@registry, @ownership_state == :released, @save[:completion].physical, snapshot_slot_locked(@attempt)]
        end
        return observer.complete(build_result) if released
        unless registry&.owns_terminal_operation?(self)
          return observer.complete(unavailable_result(Phronomy::Error.new("Agent #{recovery_kind} recovery owner no longer matches")))
        end
        unless physical
          return observer.complete(unavailable_result(Phronomy::Error.new("Original Agent save is still physically active")))
        end
        if active
          if active[:admission_unknown]
            return observer.complete(unavailable_result(active[:error] || Phronomy::Error.new("Agent #{recovery_kind} submission has no authoritative admission receipt")))
          end
          if active[:watch_error]
            refresh_slot(active[:id])
            active = @mutex.synchronize { snapshot_slot_locked(slot_for(active[:id])) }
            completion_observable = active && ((active[:logical] && active[:physical]) || active[:physical_watch])
            return observer.complete(unavailable_result(active&.fetch(:watch_error))) unless completion_observable
          end
          if active[:kind] != kind
            return observer.complete(unavailable_result(Phronomy::Error.new("A different Agent #{recovery_kind} recovery operation is physically active")))
          end
          @mutex.synchronize { @attempt[:observers] << observer }
          finish_attempt(active[:id])
          return
        end
        if @mutex.synchronize { @confirmation == :committed }
          return observer.complete(apply_confirmation)
        end
        # A successful late worker result is stronger than its abandoned task.
        outcome = @mutex.synchronize { @save[:completion].physical && @save[:completion].result }
        if outcome
          remember_post(outcome)
          return observer.complete(apply_confirmation)
        end
        if kind == :submission
          unless @mutex.synchronize { @submission_state == :not_admitted }
            return observer.complete(unavailable_result(Phronomy::Error.new("Agent #{recovery_kind} submission was not authoritatively refused")))
          end
          return begin_submission_retry(observer)
        end
        evidence, prepared_input, persistence = @mutex.synchronize { [@evidence, @prepared_input, @persistence] }
        unless evidence || prepared_input
          return observer.complete(unavailable_result(Phronomy::Error.new("Agent #{recovery_kind} save has no complete captured proposal")))
        end
        id = Object.new.freeze
        @mutex.synchronize do
          @attempt = new_slot(id, kind)
          @attempt[:observers] << observer
        end
        task = submit_recovery_worker(id) do
          unless evidence
            evidence = prepared_input.materialize(persistence: persistence)
            raise Phronomy::Error, "Complete Agent outcome proposal could not construct its persistence proof" unless evidence
            capture_evidence(evidence)
          end
          result = evidence.public_send(kind, persistence: persistence, original_error: @original_error)
          capture_worker(id, result, nil)
          result
        rescue Exception => error # rubocop:disable Lint/RescueException
          capture_worker(id, nil, error)
          raise
        end
        watch(task, id)
      rescue => error
        if task || (id && @mutex.synchronize { slot_for(id)&.fetch(:admission_unknown) })
          delivery_failed(id, error)
        else
          observers = close_attempt(defined?(id) && id)
          (observers.empty? ? [observer] : observers).each { |item| item.complete(unavailable_result(error)) }
        end
      end

      def begin_submission_retry(observer)
        id = Object.new.freeze
        @mutex.synchronize do
          @attempt = new_slot(id, :submission)
          @attempt[:observers] << observer
        end
        task = submit_terminal_worker(id)
        watch(task, id)
      rescue => error
        if task || @mutex.synchronize { slot_for(id)&.fetch(:admission_unknown) }
          # A returned handle can be polled later. Without one, physical completion
          # remains unknown even if a hidden worker eventually publishes a value.
          delivery_failed(id, error)
        else
          close_attempt(id).each { |item| item.complete(unavailable_result(error)) }
        end
      end

      def finish_attempt(id)
        refresh_slot(id)
        slot = @mutex.synchronize { snapshot_slot_locked(slot_for(id)) }
        return unless slot && slot[:logical] && slot[:physical]
        if slot[:error] && !slot[:error].is_a?(StandardError)
          close_attempt(id).each { |observer| observer.fail(slot[:error]) }
          return
        end
        result = slot[:result]
        observation = if slot[:kind] == :submission
          if result
            remember_post(result)
            apply_confirmation
          else
            unavailable_result(slot[:error] || Phronomy::Error.new("Agent #{recovery_kind} submission produced no confirmed outcome"))
          end
        elsif result&.disposition == :committed
          intended = @mutex.synchronize { @intended }
          if intended
            remember_post(intended)
            apply_confirmation
          else
            unavailable_result(Phronomy::Error.new("Agent #{recovery_kind} proof has no retained semantic outcome"))
          end
        elsif result&.disposition == :not_committed
          build_result(outcome: :confirmed_pre, error: result.read_error && diagnostic(result.read_error))
        else
          error = slot[:error] || result&.read_error
          build_result(outcome: error ? :unavailable : :unresolved, error: error && diagnostic(error))
        end
        close_attempt(id).each_with_index do |observer, index|
          observer.complete(index.zero? ? observation : build_result(outcome: observation.outcome, error: observation.error))
        end
      rescue => error
        close_attempt(id).each { |observer| observer.complete(unavailable_result(error)) }
      end

      def close_attempt(id)
        @mutex.synchronize do
          return [] unless id && @attempt && @attempt[:id].equal?(id)
          observers = @attempt[:observers]
          @attempt = nil
          observers
        end
      end

      def remember_post(outcome)
        raise Phronomy::Error, "Agent #{recovery_kind} save returned no semantic outcome" unless outcome
        execution = outcome.execution
        observation = if execution.terminal?
          # The worker already decoded this observation from the exact captured
          # content. Publication must not revisit mutable output or exception code.
          @mutex.synchronize { @evidence&.outcome&.execution_observation } ||
            raise(Phronomy::Error, "Agent #{recovery_kind} save has no captured execution observation")
        end
        @mutex.synchronize do
          @confirmation = :committed
          @intended = outcome
          @revision = execution.execution_revision
          @execution_observation = observation
          @saved_outcome = case outcome.type
          when :completed, :failed then :terminal
          when :coordination_wait then :coordination_wait
          when :suspended then :approval_wait
          else raise Phronomy::Error, "Unsupported captured outcome: #{outcome.type.inspect}"
          end
          @approval_request = outcome.approval_request if outcome.type == :suspended
        end
      end

      def apply_confirmation
        coordinator, outcome = @mutex.synchronize { [@coordinator, @intended] }
        return build_result if @mutex.synchronize { @ownership_state == :released }
        apply_to_owner(coordinator, outcome)
        build_result
      rescue => error
        mark_uncertain_on_owner(error)
        build_result(error: diagnostic(error))
      end

      def unavailable_result(error)
        build_result(outcome: :unavailable, error: diagnostic(error))
      end

      def build_result(outcome: nil, error: nil)
        state = @mutex.synchronize do
          [@confirmation, @application_state, @ownership_state, @revision, @execution_observation,
            @submission_state, @saved_outcome, @approval_request]
        end
        confirmation, application, ownership, revision, execution, submission, saved_outcome, approval_request = state
        outcome = :confirmed_post if confirmation == :committed
        recovery_result_class.new(recovery: @recovery, outcome: outcome || :unavailable,
          application_state: application, ownership_state: ownership,
          revision: revision, execution: execution && ExecutionObservation.new(**execution.to_h),
          submission_state: submission, error: error, **receipt_details(saved_outcome, approval_request))
      end

      def recovery_class = OutcomeRecovery
      def recovery_result_class = OutcomeRecoveryResult
      def recovery_error_class = OutcomeRecoveryError

      def receipt_details(saved_outcome, approval_request) = {saved_outcome: saved_outcome, approval_request: approval_request}

      def apply_to_owner(coordinator, outcome)
        coordinator.send(:apply_retained_outcome_on_event_loop, self, outcome)
      end

      def diagnostic(error)
        @mutex.synchronize { diagnostic_locked(error) }
      end

      def diagnostic_locked(error)
        return error if error.is_a?(recovery_error_class) && error.recovery.equal?(@recovery)
        recovery_error_class.new(recovery: @recovery,
          error: error || Phronomy::Error.new("Agent #{recovery_kind} outcome requires reconciliation"),
          original_error: @original_error || error)
      end
    end
  end
end
