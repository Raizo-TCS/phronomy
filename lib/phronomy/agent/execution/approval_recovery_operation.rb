# frozen_string_literal: true

require "securerandom"
require "weakref"

module Phronomy
  module Agent
    # Retains one original approval decision until its saved pre/post state and
    # exact local continuation are known. Workers publish facts; only the original
    # EventLoop may restore the wait or start the already-authorized continuation.
    # @api private
    class ApprovalRecoveryOperation
      Observe = Data.define(:operation, :observer)
      Ready = Data.define(:operation, :attempt_id)

      attr_reader :agent, :coordinator, :environment, :agent_id, :execution_id,
        :approval_request_id, :approved, :recovery_id, :recovery, :command,
        :request, :invocation, :suspended_cancellation, :continuation_plan

      def initialize(agent:, coordinator:, environment:, command:, request:, invocation:,
        suspended_cancellation:, committer:)
        @agent, @coordinator, @environment = agent, coordinator, environment
        @agent_reference = WeakRef.new(agent)
        @registry, @persistence, @committer = environment.registry, agent.persistence, committer
        @command, @request, @invocation = command, request, invocation
        task = request.result_task
        @hosted_context = task.respond_to?(:hosted_context) ? task.hosted_context : nil
        @parent_wait = task.respond_to?(:parent_wait) ? task.parent_wait : nil
        @suspended_cancellation = suspended_cancellation
        @agent_id, @execution_id = agent.agent_id.to_s.freeze, command.execution_id
        @approval_request_id, @approved = command.approval_request_id, command.approved
        @recovery_id = SecureRandom.uuid.freeze
        @recovery = ApprovalRecovery.send(:new, self)
        @mutex = Mutex.new
        @attempts = Phronomy::RetainedAttempts.new(mutex: @mutex,
          on_worker_recorded: ->(id, _result, error) { @original_error ||= error if id.nil? })
        @evidence = @intended = @confirmation = nil
        @write_started = false
        @unwritten_before = nil
        @original_error = @last_error = nil
        @uncertain = @initial_delivered = false
        @application_state, @continuation_state = :pending, :pending
        @canonical_task = @continuation_plan = nil
      end

      def belongs_to?(candidate)
        @agent_reference.__getobj__.equal?(candidate)
      rescue WeakRef::RefError
        false
      end

      def pending? = @mutex.synchronize { @uncertain && @continuation_state == :pending }
      def applied? = @mutex.synchronize { @application_state == :applied }
      def resolved? = @mutex.synchronize { resolved_locked? }
      def application_applied! = @mutex.synchronize { @application_state = :applied }

      def captured_cancellation_requested?
        @mutex.synchronize { (@evidence&.before || @unwritten_before)&.fetch(:agent)&.fetch(4) == true }
      end

      def resolution_permitted?
        @mutex.synchronize do
          @resolution_target && @application_state == :applied &&
            @attempts.quiescent_locked?
        end
      end

      # Registry publishes this only after removing the exact retained entry.
      def resolution_released!
        @mutex.synchronize do
          @continuation_state = @resolution_target
          @resolution_target = nil
        end
      end

      def continuation_completed!(state)
        @mutex.synchronize { @resolution_target = state }
        unless @registry.resolve_approval_operation(self)
          raise Phronomy::Error, "Approval continuation ownership changed before resolution"
        end
      rescue => error
        # A wrapper may lose the reply after the registry performed its atomic
        # removal/publication. An exception before that point cannot resolve us.
        raise error unless resolved?
      ensure
        @mutex.synchronize { @resolution_target = nil }
      end

      def continue_terminal_if_ready
        return unless resolved? && @terminal_continuation
        continuation, @terminal_continuation = @terminal_continuation, nil
        continuation.call
      end

      def prepare_continuation
        return @continuation_plan if @continuation_plan
        prepare_continuation_task unless @canonical_task
        owner_coordinator = coordinator
        @continuation_plan = ApprovalContinuationPlan.new(environment: environment,
          invocation: invocation, result_task: @canonical_task, approved: approved,
          config: request.config, cancel_requested: captured_cancellation_requested?, on_complete: lambda do |**result|
            owner_coordinator.deliver_on_event_loop(ExecutionCoordinator::SessionFinishedCommand.new(
              coordinator: owner_coordinator, **result
            ))
          end)
      end

      def continuation_task = @canonical_task

      def validate_hosted_authority!
        @hosted_context&.validate_live!
      end

      def observe_continuation_once
        return if @continuation_observed
        @continuation_observed = true
        yield
      end

      # An accepted parent may cancel while another child is positively unadmitted.
      # Its terminal handoff may abandon those children, never uncertain admission.
      def parent_finished(fsm_session_id, &continuation)
        return false unless @continuation_plan&.parent_accepted? &&
          fsm_session_id.to_s == @continuation_plan.parent_id.to_s
        unless @continuation_plan.finish_parent(fsm_session_id)
          @terminal_continuation = continuation
          return false
        end
        continuation_completed!(:resumed) unless resolved?
        true
      rescue => error
        @terminal_continuation = continuation
        mark_uncertain_on_owner(error)
        false
      ensure
        retire_resolved
      end

      def start
        @registry.retain_approval_operation(self)
        retained = true
        task = submit_worker(nil) do
          @committer.commit_retained(@command,
            parent_evidence: @hosted_context&.parent_evidence,
            participant: @invocation.config[:phronomy_execution_participant],
            on_write_started: -> { @mutex.synchronize { @write_started = true } },
            on_evidence: ->(value) { @mutex.synchronize { @evidence = value } },
            on_outcome: ->(value) { @mutex.synchronize { @intended = value } })
        end
        watch(nil)
        self
      rescue => error
        raise unless retained
        if task
          mark_uncertain_on_owner(error)
        else
          signal(nil)
        end
        self
      end

      def observe
        observer = Phronomy::TaskResult.deferred(name: "agent-approval-reconcile:#{recovery_id}")
        @attempts.register(observer)
        registry, resolved = @mutex.synchronize { [@registry, resolved_locked?] }
        if resolved
          observer.complete(build_result)
        elsif !registry || !registry.post(Observe.new(operation: self, observer: observer), completion: delivery_observer(observer))
          observer.complete(unavailable_result(Phronomy::RuntimeShutdownError.new("Original Agent owner is unavailable")))
        end
        observer
      rescue => error
        observer&.complete(unavailable_result(error))
        observer || raise
      end

      def deliver(message)
        case message
        when Observe then observe_on_owner(message.observer)
        when Ready then message.attempt_id ? finish_attempt(message.attempt_id) : deliver_initial
        else raise Phronomy::Error, "unsupported Agent approval recovery message"
        end
      ensure
        retire_resolved
      end

      def shutdown(error)
        failure = fail_original(error)
        @attempts.observers.each { |observer| observer.complete(unavailable_result(error)) }
        failure
      end

      def retain_original_waiters(_waiters)
        # The original invocation still represents the Agent job, not this save.
        # Shutdown may fail it logically but cannot acknowledge its physical end.
        acknowledge_original_if_quiet
      end

      def fail_original(error)
        failure = @mutex.synchronize do
          @uncertain = true
          @last_error = error
          @original_error ||= error
          diagnostic_locked(error)
        end
        @request&.result_task&.fail(failure)
        acknowledge_original_if_quiet
        failure
      end

      private

      def prepare_continuation_task
        @canonical_task = @coordinator.send(:build_retained_approval_task,
          name: "approval-continuation:#{recovery_id}", parent_wait: @parent_wait,
          hosted_context: @hosted_context)
        original = @request.result_task
        original.bind_hosted_continuation(@canonical_task) if @hosted_context
        @canonical_task.on_complete do |value, error|
          original.finish_operation! if original.respond_to?(:finish_operation!)
          error ? original.fail(error) : original.complete(value)
        end
        # The canonical task acquires its lease before this original decision
        # relinquishes its own. Its still-open normal observation keeps only
        # the guarded detach bridge, never a second unload-blocking lease.
        original.finish_operation! if @hosted_context
      end

      def resolved_locked?
        @application_state == :applied && %i[restored resumed].include?(@continuation_state) &&
          @attempts.quiescent_locked?
      end

      def acknowledge_original_if_quiet
        task = @mutex.synchronize { @request&.result_task if @uncertain && @attempts.snapshot_locked(nil)[:physical] }
        task.finish_operation! if task.respond_to?(:finish_operation!)
      end

      # Public capabilities can outlive their job. Keep only the immutable
      # receipt, weak identity and independent canonical execution observation.
      # Called after the enclosing owner delivery has finished using the proposal.
      def retire_resolved
        @mutex.synchronize do
          return unless resolved_locked? && !@attempts.active_snapshot_locked
          @agent = @coordinator = @environment = @registry = @persistence = @committer = nil
          @command = @request = @invocation = @suspended_cancellation = @parent_wait = nil
          if @continuation_state == :restored
            @hosted_context&.release!
            @hosted_context = nil
          end
          @evidence = @intended = @continuation_plan = @terminal_continuation = nil
          @unwritten_before = nil
          @attempts.release_references_locked(nil)
          @original_error = @last_error = nil
        end
      end

      def submit_worker(id, &work)
        @attempts.submit(id, submitter: @environment,
          missing_handle_message: "Agent approval submission returned no task handle", &work)
      end

      def watch(id)
        @attempts.watch(id) do |event|
          acknowledge_original_if_quiet if id.nil? && event == :physical
          signal(id)
        end
      end

      def refresh_attempt(id)
        acknowledge_original_if_quiet if @attempts.refresh(id) && id.nil?
      end

      def signal(id)
        registry = @mutex.synchronize { @registry }
        return unless registry
        return if registry.post(Ready.new(operation: self, attempt_id: id))
        delivery_failed(id, Phronomy::RuntimeShutdownError.new("Agent owner rejected approval evidence"))
      rescue => error
        delivery_failed(id, error)
      end

      def delivery_failed(id, error)
        return fail_original(error) unless id
        observers = @mutex.synchronize do
          @attempts.take_observers_locked(id)
        end
        observers.each { |observer| observer.complete(unavailable_result(error)) }
      end

      def delivery_observer(observer)
        Phronomy::TaskResult.deferred(name: "agent-approval-delivery:#{@recovery_id}").tap do |delivery|
          delivery.on_complete do |_value, error|
            observer.complete(unavailable_result(error)) if error
          end
        end
      end

      def deliver_initial
        refresh_attempt(nil)
        slot, uncertain, delivered = @mutex.synchronize { [@attempts.snapshot_locked(nil), @uncertain, @initial_delivered] }
        return if delivered || resolved? || !slot[:logical]
        if slot[:rejection_confirmed] && slot[:physical] && !slot[:started]
          remember_pre
          @coordinator.send(:restore_retained_approval_on_event_loop, self)
          @request.result_task.finish_operation! if @request.result_task.respond_to?(:finish_operation!)
          @request.result_task.fail(slot[:error])
          @mutex.synchronize { @initial_delivered = true }
          return
        end
        if slot[:error] || uncertain
          mark_uncertain_on_owner(slot[:error] || @last_error || Phronomy::Error.new("Approval decision requires recovery"))
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
        @coordinator.send(:approval_recovery_failed_on_event_loop, self, failure)
        failure
      end

      def observe_on_owner(observer)
        return if observer.done?
        refresh_attempt(nil)
        return observer.complete(build_result) if resolved?
        unless @registry.owns_approval_operation?(self)
          return observer.complete(unavailable_result(Phronomy::Error.new("Agent approval recovery owner no longer matches")))
        end
        physical, active = @mutex.synchronize { [@attempts.snapshot_locked(nil)[:physical], @attempts.active_snapshot_locked] }
        unless physical
          return observer.complete(unavailable_result(Phronomy::Error.new("Original approval save has no physical completion proof")))
        end
        return observe_active_attempt(observer, active) if active
        # Hosted and native relationships require current authority for every
        # unfinished continuation. An unwritten decision also requires a fresh
        # exact wait observation; neither path may reuse historical permission.
        fresh_authority = @hosted_context || @mutex.synchronize { !@evidence || @evidence.participation? }
        return observer.complete(apply_confirmation) if !fresh_authority && @mutex.synchronize { !@confirmation.nil? }
        outcome = @mutex.synchronize { @attempts.snapshot_locked(nil)[:result] }
        if outcome && !fresh_authority
          remember_post(outcome)
          return observer.complete(apply_confirmation)
        end
        begin_reconciliation(observer)
      rescue => error
        observer.complete(unavailable_result(error))
      end

      def observe_active_attempt(observer, active)
        if active[:admission_unknown]
          return observer.complete(unavailable_result(active[:error]))
        end
        if active[:watch_error]
          refresh_attempt(active[:id])
          active = @mutex.synchronize { @attempts.snapshot_locked(active[:id]) }
          observable = active && ((active[:logical] && active[:physical]) || active[:physical_watch])
          return observer.complete(unavailable_result(active&.fetch(:watch_error))) unless observable
        end
        @mutex.synchronize { @attempts.join_locked(active[:id], observer: observer) }
        finish_attempt(active[:id])
        nil
      end

      def begin_reconciliation(observer)
        evidence = @mutex.synchronize { @evidence }
        if !evidence && @mutex.synchronize { @write_started }
          return observer.complete(unavailable_result(Phronomy::Error.new("Approval decision has no complete captured proposal")))
        end
        id = Object.new.freeze
        @mutex.synchronize do
          @attempts.reserve_locked(id, observer: observer)
        end
        task = submit_worker(id) do
          if evidence
            evidence.reconcile(persistence: @persistence, original_error: @original_error)
          else
            @committer.observe_unwritten(@command, parent_evidence: @hosted_context&.parent_evidence,
              participant: @invocation.config[:phronomy_execution_participant], original_error: @original_error)
          end
        end
        watch(id)
      rescue => error
        if task || (id && @mutex.synchronize { @attempts.snapshot_locked(id)&.fetch(:admission_unknown) })
          delivery_failed(id, error)
        else
          observers = @attempts.retire(defined?(id) && id)
          (observers.empty? ? [observer] : observers).each { |item| item.complete(unavailable_result(error)) }
        end
      end

      def finish_attempt(id)
        refresh_attempt(id)
        slot = @mutex.synchronize { @attempts.snapshot_locked(id) }
        return unless slot && slot[:logical] && slot[:physical]
        if slot[:error] && !slot[:error].is_a?(StandardError)
          @attempts.retire(id).each { |observer| observer.fail(slot[:error]) }
          return
        end
        result = slot[:result]
        observation = if result&.disposition == :committed
          remember_post(@mutex.synchronize { @intended })
          result.continuation_error ? build_result(error: diagnostic(result.continuation_error)) : apply_confirmation
        elsif result&.disposition == :not_committed && @mutex.synchronize { @confirmation != :confirmed_post }
          @mutex.synchronize { @unwritten_before = result.evidence.before } unless @evidence
          remember_pre
          result.continuation_error ? build_result(error: diagnostic(result.continuation_error)) : apply_confirmation
        else
          error = slot[:error] || result&.read_error
          if !error && @mutex.synchronize { @confirmation == :confirmed_post }
            error = Phronomy::Persistence::StateConflictError.new("Saved approval authority no longer matches its captured evidence")
          end
          build_result(outcome: error ? :unavailable : :unresolved, error: error && diagnostic(error))
        end
        @attempts.retire(id).each_with_index do |observer, index|
          observer.complete(index.zero? ? observation : build_result(outcome: observation.outcome, error: observation.error))
        end
      rescue => error
        @attempts.retire(id).each { |observer| observer.complete(unavailable_result(error)) }
      end

      def remember_pre
        @mutex.synchronize do
          @confirmation = :confirmed_pre
          @revision = @command.expected_execution_revision
        end
      end

      def remember_post(outcome)
        raise Phronomy::Error, "Approval save returned no semantic outcome" unless outcome
        @mutex.synchronize do
          @confirmation = :confirmed_post
          @intended = outcome
          @revision = outcome.execution.execution_revision
        end
      end

      def apply_confirmation
        confirmation, outcome = @mutex.synchronize { [@confirmation, @intended] }
        return build_result if resolved?
        if confirmation == :confirmed_pre
          @coordinator.send(:restore_retained_approval_on_event_loop, self)
        else
          @coordinator.send(:apply_retained_approval_on_event_loop, self, outcome)
        end
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
          [@confirmation, @application_state, @continuation_state, @revision,
            @attempts.quiescent_locked?]
        end
        observer = (continuation == :resumed) ? execution_observer : nil
        hosted = observer && @hosted_context&.build_invocation(observation: execution_observer, detach_task: @canonical_task)
        ApprovalRecoveryResult.new(recovery: recovery, outcome: confirmation || outcome || :unavailable,
          application_state: application, continuation_state: continuation, revision: revision,
          physical_complete: physical, execution_task: observer, hosted_invocation: hosted,
          error: error)
      end

      def execution_observer
        Phronomy::TaskResult.deferred(name: "approval-execution-observer:#{recovery_id}").tap do |observer|
          @canonical_task.on_complete do |value, error|
            error ? observer.fail(error) : observer.complete(value)
          end
        end
      end

      def diagnostic(error)
        @mutex.synchronize { diagnostic_locked(error) }
      end

      def diagnostic_locked(error)
        return error if error.is_a?(ApprovalRecoveryError) && error.recovery.equal?(@recovery)
        ApprovalRecoveryError.new(recovery: @recovery,
          error: error || Phronomy::Error.new("Agent approval outcome requires reconciliation"),
          original_error: @original_error || error)
      end
    end
  end
end
