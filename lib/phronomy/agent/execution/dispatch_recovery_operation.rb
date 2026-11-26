# frozen_string_literal: true

require "securerandom"
require "weakref"

module Phronomy
  module Agent
    # Retains one original dispatch preparation across uncertain persistence and
    # lost observations. Only the original EventLoop may apply its proof or grant
    # the continuation permission; a worker never starts Provider or Tool work.
    # @api private
    class DispatchRecoveryOperation
      Observe = Data.define(:operation, :observer, :kind)
      Ready = Data.define(:operation, :attempt_id)
      RecoveryOutcome = Data.define(:proof, :result)
      private_constant :RecoveryOutcome

      attr_reader :agent, :coordinator, :environment, :agent_id, :execution_id,
        :fsm_session_id, :expected_execution_revision, :recovery_id, :recovery,
        :command, :invocation, :dispatch_kind, :continuation_task, :continuation_delivery, :preparation_error

      def initialize(agent:, coordinator:, environment:, command:, invocation:,
        dispatch_kind:, preparer:, original_waiters:)
        unless %i[provider tool].include?(dispatch_kind)
          raise ArgumentError, "unsupported Agent dispatch kind"
        end
        @agent, @coordinator, @environment = agent, coordinator, environment
        @agent_reference = WeakRef.new(agent)
        @registry, @persistence, @preparer = environment.registry, agent.persistence, preparer
        @command, @invocation, @dispatch_kind = command, invocation, dispatch_kind
        @agent_id, @execution_id = agent.agent_id.to_s.freeze, command.execution_id
        @fsm_session_id, @expected_execution_revision = command.fsm_session_id, command.expected_execution_revision
        @recovery_id = SecureRandom.uuid.freeze
        @recovery = DispatchRecovery.send(:new, self)
        @mutex = Mutex.new
        @save = new_slot(nil, :prepare)
        @attempt = nil
        @observers = []
        @original_waiters = original_waiters.dup
        @evidence = @intended = @confirmation = @revision = nil
        @original_error = @last_error = @preparation_error = nil
        @uncertain = @initial_delivered = @continuation_authorized = @continuation_returned = @barrier_started = false
        @application_state, @continuation_state = :pending, :pending
        @continuation_task = @resolution_target = @continuation_delivery = nil
      end

      def belongs_to?(candidate)
        @agent_reference.__getobj__.equal?(candidate)
      rescue WeakRef::RefError
        false
      end

      def pending? = @mutex.synchronize { @uncertain && !resolved_locked? }
      def applied? = @mutex.synchronize { @application_state == :applied }
      def resolved? = @mutex.synchronize { resolved_locked? }
      def application_applied! = @mutex.synchronize { @application_state = :applied }
      def continuation_authorized? = @mutex.synchronize { @continuation_authorized }
      def continuation_returned? = @mutex.synchronize { @continuation_returned }

      # A helper's normal return is separate from permission to invoke it. A
      # raised admission call leaves this false even when no message is pending.
      def continuation_returned!
        @mutex.synchronize do
          unless @continuation_authorized
            raise Phronomy::Error, "Agent dispatch continuation has not been authorized"
          end
          @continuation_returned = true
        end
      end

      # Taking this right precedes any call which might admit external work. A
      # raised call is not evidence of rejection and cannot restore the right.
      def authorize_continuation!
        @mutex.synchronize do
          return false if @continuation_authorized
          unless %i[confirmed_post not_prepared].include?(@confirmation) && @application_state == :applied && physically_complete_locked?
            raise Phronomy::Error, "Agent dispatch continuation requires applied preparation proof and physical completion"
          end
          @continuation_authorized = true
        end
      end

      def captured_cancellation_requested?
        @mutex.synchronize { @evidence&.before&.fetch(0)&.fetch(4) == true }
      end

      # An external matching session completion can resolve custody outside this
      # operation's own message delivery. Its caller retires only after use ends.
      def retire_after_delivery
        retire_resolved
      end

      def prepare_continuation
        @continuation_task ||= Phronomy::TaskResult.deferred(name: "dispatch-continuation:#{recovery_id}")
      end

      # Preserve the exact admitted continuation's notification custody. A
      # rejected notification may be redelivered without restarting its work.
      def prepare_continuation_delivery
        @continuation_delivery ||= DispatchContinuationDelivery.new(event_sink: invocation.event_sink)
      end

      def resolution_permitted?
        @mutex.synchronize do
          @resolution_target && @application_state == :applied && physically_complete_locked?
        end
      end

      # Registry invokes this under its removal lock, preserving one publication
      # point between retained barrier custody and the original job continuation.
      def resolution_released!
        @mutex.synchronize do
          @continuation_state = @resolution_target
          @resolution_target = nil
        end
      end

      def continuation_completed!(state = nil)
        @mutex.synchronize do
          unless @continuation_authorized
            raise Phronomy::Error, "Agent dispatch continuation has not been authorized"
          end
          expected = (@confirmation == :not_prepared) ? :stopped : :resumed
          state ||= expected
          raise Phronomy::Error, "Agent dispatch continuation contradicts its proof" unless state == expected
        end
        resolve_as(state)
      end

      # A physically finished worker which never entered its persistence barrier
      # can hand its original setup failure onward. Missing proof after barrier
      # entry is insufficient; it must remain an unresolved save instead.
      def prepare_failed_continuation!
        @mutex.synchronize do
          unless not_prepared_locked?
            raise Phronomy::Error, "Agent dispatch preparation has no positive pre-barrier failure proof"
          end
          @confirmation, @revision = :not_prepared, nil
          @preparation_error ||= @save[:completion].error
        end
      end

      def start
        @registry.retain_dispatch_operation(self)
        retained = true
        task = submit_worker(nil) do
          method = (dispatch_kind == :provider) ? :prepare_provider : :prepare_tools
          @preparer.public_send(method, @command,
            on_barrier_started: -> { @mutex.synchronize { @barrier_started = true } },
            on_evidence: ->(value) { @mutex.synchronize { @evidence = value } },
            on_outcome: ->(value) { @mutex.synchronize { @intended = value } })
        end
        watch(task, nil)
        self
      rescue => error
        raise unless retained
        task ? mark_uncertain_on_owner(error) : signal(nil)
        self
      end

      def observe(kind = :reconcile)
        unless %i[reconcile retry].include?(kind)
          raise ArgumentError, "unsupported Agent dispatch recovery operation"
        end
        observer = Phronomy::TaskResult.deferred(name: "agent-dispatch-#{kind}:#{recovery_id}")
        @mutex.synchronize { @observers << observer }
        observer.on_complete do |_value, _error|
          @mutex.synchronize do
            @observers.delete(observer)
            @attempt&.fetch(:observers)&.delete(observer)
          end
        end
        registry, resolved = @mutex.synchronize { [@registry, resolved_locked?] }
        if resolved
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

      def deliver(message)
        case message
        when Observe then observe_on_owner(message.observer, message.kind)
        when Ready then message.attempt_id ? finish_attempt(message.attempt_id) : deliver_initial
        else raise Phronomy::Error, "unsupported Agent dispatch recovery message"
        end
      ensure
        retire_resolved
      end

      def retain_original_waiters(waiters)
        @mutex.synchronize { @original_waiters |= waiters }
      end

      # Closing the original observation never acknowledges the physical end of
      # its still-live FSM or releases its operation lease.
      def fail_original(error)
        waiters, failure = @mutex.synchronize do
          @uncertain = true
          @last_error = error
          @original_error ||= error
          [@original_waiters.dup, diagnostic_locked(error)]
        end
        waiters.each { |task| task.fail(failure) }
        failure
      end

      def shutdown(error)
        failure = fail_original(error)
        @mutex.synchronize { @observers.dup }.each { |observer| observer.complete(unavailable_result(error)) }
        failure
      end

      private

      def physically_complete_locked?
        @save[:completion].physical && (!@attempt || @attempt[:completion].physical)
      end

      def resolved_locked?
        @application_state == :applied && %i[resumed stopped].include?(@continuation_state) && physically_complete_locked?
      end

      def not_prepared_locked?
        completion = @save[:completion]
        completion.physical && completion.error && !@evidence &&
          (!@barrier_started || (@save[:rejection_confirmed] && !@save[:started]))
      end

      def resolve_as(state)
        @mutex.synchronize { @resolution_target = state }
        unless @registry.resolve_dispatch_operation(self)
          raise Phronomy::Error, "Agent dispatch continuation ownership changed before resolution"
        end
      rescue => error
        raise error unless resolved?
      ensure
        @mutex.synchronize { @resolution_target = nil }
      end

      def retire_resolved
        @mutex.synchronize do
          return unless resolved_locked? && !@attempt
          @agent = @coordinator = @environment = @registry = @persistence = @preparer = nil
          @command = @invocation = @evidence = @intended = @continuation_delivery = nil
          @original_waiters = []
          @save[:completion].clear_locked
          @original_error = @last_error = @preparation_error = nil
        end
      end

      def new_slot(id, kind)
        {id: id, kind: kind, completion: PhysicalAttempt.new(mutex: @mutex),
         started: false, observers: [], rejection_confirmed: false, admission_unknown: false}
      end

      def slot_for(id)
        id.nil? ? @save : (@attempt if @attempt && @attempt[:id].equal?(id))
      end

      def submit_worker(id, &work)
        slot = @mutex.synchronize { slot_for(id) }
        refusal = lambda do |_error|
          @mutex.synchronize { slot[:rejection_confirmed] = true if slot_for(id).equal?(slot) }
        end
        task = Phronomy::Execution.submit_with_rejection_evidence(@environment, on_full: :raise, on_rejected: refusal) do
          @mutex.synchronize { slot[:started] = true }
          result = work.call
          capture_worker(id, result, nil)
          result
        rescue Exception => error # rubocop:disable Lint/RescueException
          capture_worker(id, nil, error)
          raise
        end
        raise Phronomy::Error, "Agent dispatch submission returned no task handle" unless task
        @mutex.synchronize { slot[:completion].attach_locked(task) }
        task
      rescue => error
        @mutex.synchronize do
          if slot && slot_for(id).equal?(slot)
            refused = slot[:rejection_confirmed] && !slot[:started] && !slot[:completion].task
            slot[:admission_unknown] = !refused
            slot[:completion].submission_failed_locked(error, physical: refused)
          end
        end
        raise
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
        completion.watch(task) { |_event| signal(id) }
      end

      def refresh_slot(id)
        @mutex.synchronize { slot_for(id)&.fetch(:completion) }&.refresh
      end

      def snapshot_slot_locked(slot)
        slot&.merge(slot.fetch(:completion).snapshot_locked)
      end

      def signal(id)
        registry = @mutex.synchronize { @registry }
        return unless registry
        return if registry.post(Ready.new(operation: self, attempt_id: id))
        delivery_failed(id, Phronomy::RuntimeShutdownError.new("Agent owner rejected dispatch evidence"))
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
        Phronomy::TaskResult.deferred(name: "agent-dispatch-delivery:#{recovery_id}").tap do |delivery|
          delivery.on_complete { |_value, error| observer.complete(unavailable_result(error)) if error }
        end
      end

      def deliver_initial
        refresh_slot(nil)
        slot, uncertain, not_prepared, delivered = @mutex.synchronize do
          [snapshot_slot_locked(@save), @uncertain, not_prepared_locked?, @initial_delivered]
        end
        return if delivered || resolved? || !slot[:logical]
        if not_prepared
          @mutex.synchronize { @initial_delivered = true }
          apply_preparation_failure
          return
        end
        if slot[:error] || uncertain
          mark_uncertain_on_owner(slot[:error] || @last_error || Phronomy::Error.new("Dispatch preparation requires explicit recovery"))
          @mutex.synchronize { @initial_delivered = true }
          return
        end
        return unless slot[:physical]
        @mutex.synchronize { @initial_delivered = true }
        remember_post(slot[:result])
        apply_confirmation
      rescue => error
        mark_uncertain_on_owner(error)
      end

      def mark_uncertain_on_owner(error)
        failure = fail_original(error)
        coordinator = @mutex.synchronize { @coordinator }
        coordinator&.send(:dispatch_recovery_failed_on_event_loop, self, failure)
        failure
      end

      def observe_on_owner(observer, kind)
        return if observer.done?
        refresh_slot(nil)
        return observer.complete(build_result) if resolved?
        registry, physical, active = @mutex.synchronize do
          [@registry, @save[:completion].physical, snapshot_slot_locked(@attempt)]
        end
        unless registry&.owns_dispatch_operation?(self)
          return observer.complete(unavailable_result(Phronomy::Error.new("Agent dispatch recovery owner no longer matches")))
        end
        # Ready rejection can close the original observer off the EventLoop.
        # Publish the matching domain transition before any cached outcome is
        # applied, including closure of its former stream listener.
        mark_uncertain_on_owner(@mutex.synchronize { @last_error }) if pending?
        unless physical
          return observer.complete(unavailable_result(Phronomy::Error.new("Original dispatch preparation has no physical completion proof")))
        end
        if active
          if active[:admission_unknown]
            return observer.complete(unavailable_result(active[:error]))
          end
          if active[:watch_error]
            refresh_slot(active[:id])
            active = @mutex.synchronize { snapshot_slot_locked(slot_for(active[:id])) }
            observable = active && ((active[:logical] && active[:physical]) || active[:physical_watch])
            return observer.complete(unavailable_result(active&.fetch(:watch_error))) unless observable
          end
          if active[:kind] != kind
            return observer.complete(unavailable_result(Phronomy::Error.new("A different Agent dispatch recovery operation is physically active")))
          end
          @mutex.synchronize { @attempt[:observers] << observer }
          finish_attempt(active[:id])
          return
        end
        if @mutex.synchronize { @confirmation == :not_prepared || not_prepared_locked? }
          return observer.complete(apply_preparation_failure)
        end
        # Both a reserved child and an opted-in parent need current authority
        # before new admission. A historical saved barrier alone cannot prove
        # that the same child relationships still permit its continuation.
        fresh_proof = @mutex.synchronize do
          (@command.execution.metadata["reservation"] || @evidence&.participation?) && !@continuation_authorized
        end
        if !fresh_proof && @mutex.synchronize { @confirmation == :confirmed_post }
          return observer.complete(apply_confirmation)
        end
        outcome = @mutex.synchronize { @save[:completion].result }
        if outcome
          remember_post(outcome)
          return observer.complete(apply_confirmation) unless fresh_proof
        end
        evidence, persistence, preparer = @mutex.synchronize { [@evidence, @persistence, @preparer] }
        unless evidence
          return observer.complete(unavailable_result(Phronomy::Error.new("Dispatch preparation has no complete captured proposal")))
        end
        id = Object.new.freeze
        evidence_action = @mutex.synchronize do
          # A later write or read invalidates a previously observed pre-state.
          # Keep confirmed post-state sticky, but never turn a lost retry reply
          # into a new claim that the original pre-state still holds.
          @confirmation = @revision = nil unless @confirmation == :confirmed_post
          @attempt = new_slot(id, kind)
          @attempt[:observers] << observer
          (@confirmation == :confirmed_post) ? :reconcile : kind
        end
        task = submit_worker(id) do
          proof = evidence.public_send(evidence_action, persistence: persistence, original_error: @original_error)
          result = preparer.recover_result(evidence) if proof.disposition == :committed
          RecoveryOutcome.new(proof: proof, result: result)
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

      def finish_attempt(id)
        refresh_slot(id)
        slot = @mutex.synchronize { snapshot_slot_locked(slot_for(id)) }
        return unless slot && slot[:logical] && slot[:physical]
        if slot[:error] && !slot[:error].is_a?(StandardError)
          close_attempt(id).each { |observer| observer.fail(slot[:error]) }
          return
        end
        proof, result = slot[:result]&.then { |value| [value.proof, value.result] }
        observation = if proof&.disposition == :committed
          remember_post(result)
          if proof.continuation_error
            build_result(error: diagnostic(proof.continuation_error))
          else
            apply_confirmation
          end
        elsif proof&.disposition == :not_committed && @mutex.synchronize { @confirmation != :confirmed_post }
          @mutex.synchronize { @confirmation, @revision = :confirmed_pre, expected_execution_revision }
          build_result(error: proof.read_error && diagnostic(proof.read_error))
        else
          error = slot[:error] || proof&.read_error
          if !error && @mutex.synchronize { @confirmation == :confirmed_post }
            error = Phronomy::Persistence::StateConflictError.new("Saved dispatch authority no longer matches its captured evidence")
          end
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
        raise Phronomy::Error, "Agent dispatch save returned no semantic outcome" unless outcome
        @mutex.synchronize do
          @confirmation, @revision = :confirmed_post, outcome.execution.execution_revision
          @intended = outcome
        end
      end

      def apply_preparation_failure
        prepare_failed_continuation!
        @coordinator.send(:stop_retained_dispatch_on_event_loop, self, @preparation_error)
        build_result
      rescue => error
        mark_uncertain_on_owner(error)
        build_result(error: diagnostic(error))
      end

      def apply_confirmation
        coordinator, outcome = @mutex.synchronize { [@coordinator, @intended] }
        return build_result if resolved?
        coordinator.send(:apply_retained_dispatch_on_event_loop, self, outcome)
        build_result
      rescue => error
        mark_uncertain_on_owner(error)
        build_result(error: diagnostic(error))
      end

      def unavailable_result(error)
        build_result(outcome: :unavailable, error: diagnostic(error))
      end

      def build_result(outcome: nil, error: nil)
        confirmation, application, continuation, revision, physical = @mutex.synchronize do
          [@confirmation, @application_state, @continuation_state, @revision, physically_complete_locked?]
        end
        DispatchRecoveryResult.new(recovery: recovery, outcome: confirmation || outcome || :unavailable,
          application_state: application, continuation_state: continuation, revision: revision,
          physical_complete: physical, execution_task: %i[resumed stopped].include?(continuation) ? execution_observer : nil,
          error: error)
      end

      def execution_observer
        Phronomy::TaskResult.deferred(name: "dispatch-execution-observer:#{recovery_id}").tap do |observer|
          @continuation_task.on_complete { |value, error| error ? observer.fail(error) : observer.complete(value) }
        end
      end

      def diagnostic(error)
        @mutex.synchronize { diagnostic_locked(error) }
      end

      def diagnostic_locked(error)
        return error if error.is_a?(DispatchRecoveryError) && error.recovery.equal?(@recovery)
        DispatchRecoveryError.new(recovery: @recovery,
          error: error || Phronomy::Error.new("Agent dispatch outcome requires reconciliation"),
          original_error: @original_error || error)
      end
    end
  end
end
