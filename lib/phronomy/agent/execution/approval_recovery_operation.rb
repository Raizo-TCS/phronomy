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
        @suspended_cancellation = suspended_cancellation
        @agent_id, @execution_id = agent.agent_id.to_s.freeze, command.execution_id
        @approval_request_id, @approved = command.approval_request_id, command.approved
        @recovery_id = SecureRandom.uuid.freeze
        @recovery = ApprovalRecovery.send(:new, self)
        @mutex = Mutex.new
        @save = new_slot(nil)
        @attempt = nil
        @observers = []
        @evidence = @intended = @confirmation = nil
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

      def resolution_permitted?
        @mutex.synchronize do
          @resolution_target && @application_state == :applied &&
            @save[:physical] && (!@attempt || @attempt[:physical])
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
        unless @canonical_task
          @canonical_task = OperationResult.new(agent: @agent, name: "approval-continuation:#{recovery_id}")
          original = @request.result_task
          @canonical_task.on_complete do |value, error|
            original.finish_operation! if original.respond_to?(:finish_operation!)
            error ? original.fail(error) : original.complete(value)
          end
        end
        owner_coordinator = coordinator
        @continuation_plan = ApprovalContinuationPlan.new(environment: environment,
          invocation: invocation, result_task: @canonical_task, approved: approved,
          config: request.config, on_complete: lambda do |**result|
            owner_coordinator.deliver_on_event_loop(ExecutionCoordinator::SessionFinishedCommand.new(
              coordinator: owner_coordinator, **result
            ))
          end)
      end

      def continuation_task = @canonical_task

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
            on_evidence: ->(value) { @mutex.synchronize { @evidence = value } },
            on_outcome: ->(value) { @mutex.synchronize { @intended = value } })
        end
        watch(task, nil)
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
        @mutex.synchronize { @observers.dup }.each { |observer| observer.complete(unavailable_result(error)) }
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

      def resolved_locked?
        @application_state == :applied && %i[restored resumed].include?(@continuation_state) &&
          @save[:physical] && (!@attempt || @attempt[:physical])
      end

      def acknowledge_original_if_quiet
        task = @mutex.synchronize { @request&.result_task if @uncertain && @save[:physical] }
        task.finish_operation! if task.respond_to?(:finish_operation!)
      end

      # Public capabilities can outlive their job. Keep only the immutable
      # receipt, weak identity and independent canonical execution observation.
      # Called after the enclosing owner delivery has finished using the proposal.
      def retire_resolved
        @mutex.synchronize do
          return unless resolved_locked? && !@attempt
          @agent = @coordinator = @environment = @registry = @persistence = @committer = nil
          @command = @request = @invocation = @suspended_cancellation = nil
          @evidence = @intended = @continuation_plan = @terminal_continuation = nil
          @save[:task] = @save[:result] = @save[:error] = @save[:watch_error] = nil
          @original_error = @last_error = nil
        end
      end

      def new_slot(id)
        {id: id, task: nil, started: false, physical: false, logical: false,
         result: nil, error: nil, worker_recorded: false, observers: [],
         rejection_confirmed: false, admission_unknown: false, watch_error: nil, physical_watch: false}
      end

      def slot_for(id)
        id.nil? ? @save : (@attempt if @attempt && @attempt[:id].equal?(id))
      end

      def submit_worker(id, &work)
        slot = @mutex.synchronize { slot_for(id) }
        refusal = ->(_error) { @mutex.synchronize { slot[:rejection_confirmed] = true } }
        task = Phronomy::Execution.submit_with_rejection_evidence(@environment, on_full: :raise, on_rejected: refusal) do
          @mutex.synchronize { slot[:started] = true }
          result = work.call
          capture_worker(id, result, nil)
          result
        rescue Exception => error # rubocop:disable Lint/RescueException
          capture_worker(id, nil, error)
          raise
        end
        raise Phronomy::Error, "Agent approval submission returned no task handle" unless task
        @mutex.synchronize { slot[:task] = task }
        task
      rescue => error
        @mutex.synchronize do
          if slot
            refused = slot[:rejection_confirmed] && !slot[:started] && !slot[:task]
            slot[:admission_unknown] = !refused
            slot[:logical], slot[:physical], slot[:error] = true, refused, error
          end
        end
        raise
      end

      def capture_worker(id, result, error)
        @mutex.synchronize do
          slot = slot_for(id)
          return unless slot
          slot[:result], slot[:error], slot[:worker_recorded] = result, error, true
          @original_error ||= error if id.nil?
        end
      end

      def watch(task, id)
        @mutex.synchronize { slot_for(id)[:task] = task }
        physical = task.respond_to?(:on_physical_complete)
        if physical
          task.on_physical_complete do
            @mutex.synchronize { slot_for(id)&.[]=(:physical, true) }
            acknowledge_original_if_quiet if id.nil?
            signal(id)
          end
          @mutex.synchronize { slot_for(id)&.[]=(:physical_watch, true) }
        end
        task.on_complete do |result, error|
          @mutex.synchronize do
            slot = slot_for(id)
            if slot
              slot[:logical] = true
              slot[:physical] = true unless physical
              unless slot[:worker_recorded]
                slot[:result], slot[:error] = result, error
              end
            end
          end
          signal(id)
        end
      rescue => error
        @mutex.synchronize { slot_for(id)&.[]=(:watch_error, error) }
        raise
      end

      def refresh_slot(id)
        task = @mutex.synchronize { slot_for(id)&.fetch(:task) }
        return unless task
        status, value, error = task.__snapshot
        physical = if task.respond_to?(:physical_complete?)
          task.physical_complete?
        else
          !task.respond_to?(:on_physical_complete) && status != :pending
        end
        @mutex.synchronize do
          slot = slot_for(id)
          return unless slot
          slot[:physical] ||= physical
          if status != :pending
            slot[:logical] = true
            slot[:result], slot[:error] = value, error unless slot[:worker_recorded]
          end
        end
        acknowledge_original_if_quiet if id.nil?
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
          slot = slot_for(id)
          slot ? slot[:observers].shift(slot[:observers].length) : []
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
        refresh_slot(nil)
        slot, uncertain, delivered = @mutex.synchronize { [@save.dup, @uncertain, @initial_delivered] }
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
        refresh_slot(nil)
        return observer.complete(build_result) if resolved?
        unless @registry.owns_approval_operation?(self)
          return observer.complete(unavailable_result(Phronomy::Error.new("Agent approval recovery owner no longer matches")))
        end
        physical, active = @mutex.synchronize { [@save[:physical], @attempt&.dup] }
        unless physical
          return observer.complete(unavailable_result(Phronomy::Error.new("Original approval save has no physical completion proof")))
        end
        if active
          if active[:admission_unknown]
            return observer.complete(unavailable_result(active[:error]))
          end
          if active[:watch_error]
            refresh_slot(active[:id])
            active = @mutex.synchronize { slot_for(active[:id])&.dup }
            observable = active && ((active[:logical] && active[:physical]) || active[:physical_watch])
            return observer.complete(unavailable_result(active&.fetch(:watch_error))) unless observable
          end
          @mutex.synchronize { @attempt[:observers] << observer }
          finish_attempt(active[:id])
          return
        end
        return observer.complete(apply_confirmation) if @mutex.synchronize { !@confirmation.nil? }
        outcome = @mutex.synchronize { @save[:result] }
        if outcome
          remember_post(outcome)
          return observer.complete(apply_confirmation)
        end
        evidence = @mutex.synchronize { @evidence }
        unless evidence
          return observer.complete(unavailable_result(Phronomy::Error.new("Approval decision has no complete captured proposal")))
        end
        id = Object.new.freeze
        @mutex.synchronize do
          @attempt = new_slot(id)
          @attempt[:observers] << observer
        end
        task = submit_worker(id) { evidence.reconcile(persistence: @persistence, original_error: @original_error) }
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
        slot = @mutex.synchronize { slot_for(id)&.dup }
        return unless slot && slot[:logical] && slot[:physical]
        if slot[:error] && !slot[:error].is_a?(StandardError)
          close_attempt(id).each { |observer| observer.fail(slot[:error]) }
          return
        end
        result = slot[:result]
        observation = if result&.disposition == :committed
          remember_post(@mutex.synchronize { @intended })
          apply_confirmation
        elsif result&.disposition == :not_committed
          remember_pre
          apply_confirmation
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
            @save[:physical] && (!@attempt || @attempt[:physical])]
        end
        ApprovalRecoveryResult.new(recovery: recovery, outcome: confirmation || outcome || :unavailable,
          application_state: application, continuation_state: continuation, revision: revision,
          physical_complete: physical, execution_task: (continuation == :resumed) ? execution_observer : nil,
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
