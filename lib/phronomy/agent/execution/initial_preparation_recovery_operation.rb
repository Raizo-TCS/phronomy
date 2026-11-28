# frozen_string_literal: true

require "securerandom"
require "weakref"

module Phronomy
  module Agent
    # Owns one original initial admission through its durable save stages. The
    # mutex protects captured stage facts and shared attempt bookkeeping; only
    # EventLoop changes Runtime admission or installs the execution.
    # @api private
    class InitialPreparationRecoveryOperation
      Observe = Data.define(:operation, :observer, :kind)
      Ready = Data.define(:operation, :attempt_id)
      RecoveryOutcome = Data.define(:proof, :result, :cancelled_admission)
      private_constant :RecoveryOutcome

      attr_reader :agent, :coordinator, :environment, :agent_id, :execution_id,
        :recovery_id, :recovery, :command, :request, :controls, :authority
      attr_accessor :filtered_input, :initial_session, :session_registration_attempted

      def initialize(agent:, coordinator:, environment:, command:, request:)
        @agent, @coordinator, @environment, @command, @request = agent, coordinator, environment, command, request
        @agent_reference = WeakRef.new(agent)
        @registry, @persistence = environment.registry, agent.persistence
        @agent_id, @execution_id = agent.agent_id, request.config.fetch(:phronomy_reserved_execution_id)
        @controls = request.controls
        @recovery_id = SecureRandom.uuid.freeze
        @recovery = InitialPreparationRecovery.send(:new, self)
        @mutex = Mutex.new
        @attempts = Phronomy::RetainedAttempts.new(mutex: @mutex)
        @preparer = InitialPreparation.new(agent: agent, persistence: @persistence, owner: self)
        @stage, @application_state, @continuation_state = :admission, :pending, :pending
        @uncertain = @save_entered = @preparation_started = @initial_delivered = false
        @checkpoint = @confirmation = @original_error = @last_error = nil
        @original_waiters = [request.result_task]
      end

      def belongs_to?(candidate)
        @agent_reference.__getobj__.equal?(candidate)
      rescue WeakRef::RefError
        false
      end

      def pending? = @mutex.synchronize { @uncertain && !resolved_locked? }
      def resolved? = @mutex.synchronize { resolved_locked? }
      def save_entered? = @mutex.synchronize { @save_entered }
      def save_entered! = @mutex.synchronize { @save_entered = true }
      def save_returned! = @mutex.synchronize { @save_entered = false }
      def capture_supported? = !@admission_participant || @admission_participant.respond_to?(:initial_recovery_authority, true)

      def admission_started!(admission, participant)
        @admission_participant = participant
        # An arbitrary callback may own writes outside the Agent proposal.
        save_entered! if participant && !capture_supported?
      end

      def capture_authority(admission, scope)
        @authority ||= @admission_participant&.__send__(:initial_recovery_authority,
          admission, scope: scope, persistence: @persistence)
      end

      def admitted_execution
        @mutex.synchronize { @admitted_execution }
      end

      def preparation_started!
        @mutex.synchronize do
          raise Phronomy::Error, "Initial preparation has already started" if @preparation_started
          @preparation_started = true
          @save_entered = false
        end
        controls.check_start!
      end

      def begin_stage(stage)
        @mutex.synchronize do
          @stage, @checkpoint, @confirmation, @save_entered = stage, nil, nil, false
        end
      end

      # Worker records complete values before any mutable save. No callback or
      # storage operation executes while this owner mutex is held.
      def capture(evidence, **values)
        @mutex.synchronize do
          @stage = evidence.stage
          @checkpoint = values.merge(evidence: evidence).freeze
          @admitted_execution = evidence.execution if evidence.stage == :admission
          @confirmation = nil
        end
      end

      def start
        @registry.retain_initial_preparation(self)
        task = submit(nil) { @preparer.prepare(command) }
        request.result_task.track(task)
        watch(nil)
        self
      rescue
        signal(nil)
        self
      end

      def observe(kind)
        observer = Phronomy::TaskResult.deferred(name: "initial-preparation-#{kind}:#{recovery_id}")
        @attempts.register(observer)
        if resolved?
          observer.complete(build_result)
        elsif !@registry.post(Observe.new(operation: self, observer: observer, kind: kind),
          completion: delivery_observer(observer))
          observer.complete(unavailable(Phronomy::RuntimeShutdownError.new("Original initial preparation owner is unavailable")))
        end
        observer
      rescue => error
        observer&.complete(unavailable(error))
        observer || raise
      end

      def deliver(message)
        case message
        when Observe then observe_on_owner(message.observer, message.kind)
        when Ready then message.attempt_id ? finish_attempt(message.attempt_id) : deliver_initial
        end
      ensure
        retire_resolved
      end

      def retain_original_waiters(waiters)
        @mutex.synchronize { @original_waiters |= waiters }
      end

      def shutdown(error)
        failure = fail_original(error)
        @attempts.observers.each { |observer| observer.complete(unavailable(error)) }
        failure
      end

      def application_request
        return request unless @mutex.synchronize { @uncertain } && request.result_task.done?
        @continuation_request ||= begin
          result_task = OperationResult.new(agent: @agent, name: "initial-preparation-continuation:#{execution_id}")
          controls.bind(result_task, track_completion: false)
          request.with(result_task: result_task, on_event: nil, approval_listener: nil)
        end
      end

      def original_delivery?
        @mutex.synchronize { !@uncertain && @attempts.quiescent_locked? }
      end

      # This ordinary-delivery path has positive local non-admission evidence.
      # Preserve the existing terminal protocol, including participant behavior.
      def handover_setup_failure(prepared, error)
        @terminal_handover_pending = true
        custody = @coordinator.send(:begin_terminal_after_start_failure_on_event_loop,
          request: request, prepared: prepared, error: error)
        if custody&.accepted? && @registry.transfer_initial_terminal_custody(self, custody)
          controls = @controls
          request.result_task.on_physical_complete { controls.close }
          @mutex.synchronize { @terminal_transferred = true }
        else
          @mutex.synchronize do
            @uncertain = true
            @original_error ||= custody&.error || error
            @last_error = custody&.error || error
          end
          # The legacy terminal path may already have reported its own error.
          fail_original(@last_error) unless request.result_task.done?
        end
        nil
      end

      def resolution_permitted?
        @mutex.synchronize { @attempts.quiescent_locked? && @resolution_state }
      end

      # Called only in the registry's matching-token removal transaction.
      def resolution_released!
        @mutex.synchronize do
          @application_state, @continuation_state = :applied, @resolution_state
          @resolution_state = nil
        end
      end

      private

      def resolved_locked?
        @application_state == :applied && %i[resumed stopped].include?(@continuation_state) && @attempts.quiescent_locked?
      end

      def submit(id, &work)
        @attempts.submit(id, submitter: @environment,
          missing_handle_message: "Initial preparation submission returned no task handle", &work)
      end

      def watch(id)
        @attempts.watch(id) { |_event| signal(id) }
      end

      def signal(id)
        registry = @mutex.synchronize { @registry }
        return unless registry
        return if registry.post(Ready.new(operation: self, attempt_id: id))
        delivery_failed(id, Phronomy::RuntimeShutdownError.new("Initial preparation evidence notification rejected"))
      rescue => error
        delivery_failed(id, error)
      end

      def delivery_failed(id, error)
        return fail_original(error) unless id
        observers = @mutex.synchronize { @attempts.take_observers_locked(id) }
        observers.each { |observer| observer.complete(unavailable(error)) }
      end

      def delivery_observer(observer)
        Phronomy::TaskResult.deferred(name: "initial-preparation-delivery:#{recovery_id}").tap do |task|
          task.on_complete { |_result, error| observer.complete(unavailable(error)) if error }
        end
      end

      def fail_original(error)
        waiters, failure = @mutex.synchronize do
          @uncertain = true
          @original_error ||= error
          @last_error = error
          [@original_waiters.dup, diagnostic_locked(error)]
        end
        waiters.each do |task|
          task.respond_to?(:settle) ? task.settle(error: failure) : task.fail(failure)
        end
        failure
      end

      def deliver_initial
        @attempts.refresh(nil)
        slot, delivered = @mutex.synchronize { [@attempts.snapshot_locked(nil), @initial_delivered] }
        return if delivered || resolved? || !slot[:logical]
        # Once uncertainty was exposed, only an explicit observation may grant
        # continuation. A delayed original notification cannot race its lane.
        return if @mutex.synchronize { @uncertain }
        if slot[:error]
          if slot[:physical] && slot[:rejection_confirmed] && !slot[:started]
            @mutex.synchronize { @confirmation = :not_prepared }
            resolve_without_admission(slot[:error])
          else
            fail_original(slot[:error])
            @registry.mark_agent_admission_recovery_required(agent_id, owner_token: request.admission_token)
          end
        elsif slot[:physical]
          apply_result(slot[:result])
        else
          return
        end
        @mutex.synchronize { @initial_delivered = true }
      rescue => error
        fail_original(error)
      end

      def observe_on_owner(observer, kind)
        return if observer.done?
        @attempts.refresh(nil)
        return observer.complete(build_result) if resolved?
        unless @registry.owns_initial_preparation?(self)
          return observer.complete(unavailable(Phronomy::Error.new("Initial preparation owner no longer matches")))
        end
        slot, active = @mutex.synchronize { [@attempts.snapshot_locked(nil), @attempts.active_snapshot_locked] }
        unless slot[:physical]
          return observer.complete(unavailable(Phronomy::Error.new("Original initial preparation has no physical completion proof")))
        end
        if active
          return observer.complete(unavailable(active[:error])) if active[:admission_unknown]
          if active[:kind] != kind
            return observer.complete(unavailable(Phronomy::Error.new("Another initial recovery operation is physically active")))
          end
          @mutex.synchronize { @attempts.join_locked(active[:id], observer: observer) }
          return finish_attempt(active[:id])
        end
        if slot[:rejection_confirmed] && !slot[:started] && slot[:error]
          @mutex.synchronize { @confirmation = :not_prepared }
          resolve_without_admission(slot[:error])
          return observer.complete(build_result)
        end
        if slot[:result]&.admission_outcome == :not_established && !@mutex.synchronize { @checkpoint }
          apply_result(slot[:result])
          return observer.complete(build_result)
        end
        if initial_session && session_registration_attempted &&
            (!environment.respond_to?(:session_admitted?) || environment.session_admitted?(initial_session.id))
          return observer.complete(unavailable(Phronomy::Error.new("Initial session has no positive non-admission proof for recovery")))
        end
        if @terminal_handover_pending
          return observer.complete(unavailable(Phronomy::Error.new("Initial setup is awaiting terminal ownership; activation cannot be repeated")))
        end
        begin_attempt(observer, kind)
      rescue => error
        observer.complete(unavailable(error))
      end

      def begin_attempt(observer, kind)
        checkpoint = @mutex.synchronize { @checkpoint }
        unless checkpoint
          return observer.complete(unavailable(Phronomy::Error.new("Initial preparation has no complete captured proposal")))
        end
        id = Object.new.freeze
        @mutex.synchronize do
          @confirmation = nil unless @confirmation == :confirmed_post
          @attempts.reserve_locked(id, kind: kind, observer: observer)
        end
        submit(id) { recover_checkpoint(checkpoint, kind) }
        watch(id)
      rescue => error
        slot = @mutex.synchronize { @attempts.snapshot_locked(id) } if id
        if slot && (slot[:admission_unknown] || !slot[:physical])
          delivery_failed(id, error)
        else
          @attempts.retire(id).each { |item| item.complete(unavailable(error)) }
        end
      end

      def recover_checkpoint(checkpoint, kind)
        cancelled = captured_control_error unless checkpoint.fetch(:evidence).stage == :failure
        proof = checkpoint.fetch(:evidence).public_send(cancelled ? :reconcile : kind,
          persistence: @persistence, original_error: @original_error)
        result = nil
        cancelled_admission = nil
        if proof.disposition == :not_committed && cancelled
          if checkpoint.fetch(:evidence).stage == :admission
            cancelled_admission = cancelled
          else
            result = @preparer.stop(checkpoint, cancelled, before: true)
          end
        elsif proof.disposition == :committed
          error = cancelled || proof.continuation_error
          result = if error.is_a?(Phronomy::CancellationError) || cancelled
            @preparer.stop(checkpoint, error)
          elsif !error
            @preparer.continue(checkpoint)
          end
        end
        RecoveryOutcome.new(proof: proof, result: result, cancelled_admission: cancelled_admission)
      end

      def captured_control_error
        controls.check_start!
        controls.token&.raise_if_cancelled!
        nil
      rescue => error
        error
      end

      def finish_attempt(id)
        @attempts.refresh(id)
        slot = @mutex.synchronize { @attempts.snapshot_locked(id) }
        return unless slot && slot[:logical] && slot[:physical]
        outcome = slot[:result]
        receipt = if slot[:error]
          @mutex.synchronize { @last_error = slot[:error] }
          unavailable(slot[:error])
        elsif outcome.cancelled_admission
          @mutex.synchronize { @confirmation = :confirmed_pre }
          resolve_without_admission(outcome.cancelled_admission)
          build_result
        elsif outcome.result
          apply_result(outcome.result)
          build_result
        elsif outcome.proof.disposition == :committed
          @mutex.synchronize { @confirmation = :confirmed_post }
          build_result(error: diagnostic(outcome.proof.continuation_error))
        elsif outcome.proof.disposition == :not_committed
          @mutex.synchronize { @confirmation = :confirmed_pre }
          build_result(error: outcome.proof.read_error && diagnostic(outcome.proof.read_error))
        else
          unavailable(outcome.proof.read_error)
        end
        @attempts.retire(id).each_with_index do |observer, index|
          observer.complete(index.zero? ? receipt : build_result(error: receipt.error))
        end
      rescue => error
        @attempts.retire(id).each { |observer| observer.complete(unavailable(error)) }
      end

      def apply_result(result)
        unless result
          raise Phronomy::Error, "Initial preparation returned no result"
        end
        case result.admission_outcome
        when :not_established
          @mutex.synchronize { @confirmation = :not_prepared }
          resolve_without_admission(result.error)
        when :active, :terminal
          @mutex.synchronize { @confirmation = :confirmed_post }
          if result.admission_outcome == :terminal && @mutex.synchronize { @checkpoint&.fetch(:evidence)&.stage == :failure }
            capture_terminal_observation(result)
          end
          @coordinator.send(:apply_retained_initial_preparation_on_event_loop, self, result)
          return if @terminal_handover_pending
          state = (result.admission_outcome == :active) ? :resumed : :stopped
          resolve(state)
          (state == :resumed) ? controls.track(application_request.result_task) : controls.close
        else
          raise(result.error || Phronomy::Error.new("Initial preparation requires current durable recovery"))
        end
      end

      def resolve_without_admission(error)
        @execution_observation = Phronomy::TaskResult.deferred(name: "initial-unadmitted:#{recovery_id}")
        @execution_observation.fail(error)
        resolve(:stopped)
        controls.close
        @coordinator.send(:deliver_start_failure_on_event_loop, request, error) unless request.result_task.done?
      end

      def resolve(state)
        @mutex.synchronize { @resolution_state = state }
        unless @registry.resolve_initial_preparation(self, state: state)
          raise Phronomy::Error, "Initial preparation token changed before handover"
        end
      end

      # A saved terminal failure is an exact execution value, not the original
      # failed observation. Its diagnostic bytes were captured before the save.
      def capture_terminal_observation(result)
        evidence = @mutex.synchronize { @checkpoint.fetch(:evidence) }
        execution = result.execution
        diagnostic = evidence.content_writes.find { |write| write.reference == execution.error_ref }
        value = {execution_id: execution_id, agent_id: agent_id,
                 status: execution.status, phase: execution.phase,
                 result_ref: execution.result_ref, error_ref: execution.error_ref,
                 result: nil, raw_output: nil, output: nil,
                 error: diagnostic && Phronomy::CanonicalJSON.load(diagnostic.bytes)}
        @execution_observation = Phronomy::TaskResult.deferred(name: "initial-execution:#{recovery_id}")
        @execution_observation.complete(Phronomy::Values::Immutable.copy(value))
      end

      def execution_observer
        canonical, connect = @mutex.synchronize do
          unless @execution_observation
            @execution_observation = Phronomy::TaskResult.deferred(name: "initial-execution:#{recovery_id}")
            connect = true
          end
          [@execution_observation, connect]
        end
        if connect
          task = (@continuation_request || request).result_task
          persistence, environment, id = @persistence, @environment, execution_id
          task.on_complete do |_value, failure|
            read = environment.submit(on_full: :raise) do
              saved = persistence.result(id)
              unless %i[completed failed cancelled blocked rejected handed_off].include?(saved[:status])
                raise(failure || Phronomy::ExecutionRehydrationRequiredError.new("Execution #{id} needs its next explicit continuation"))
              end
              saved.merge(output: saved[:result]).freeze
            end
            read.on_complete { |value, error| error ? canonical.fail(error) : canonical.complete(value) }
          rescue => error
            canonical.fail(error)
          end
        end
        Phronomy::TaskResult.deferred(name: "initial-execution-observer:#{recovery_id}").tap do |observer|
          canonical.on_complete { |value, error| error ? observer.fail(error) : observer.complete(value) }
        end
      end

      def retire_resolved
        ready, needs_observation = @mutex.synchronize do
          [(resolved_locked? || @terminal_transferred) && !@attempts.active_snapshot_locked,
            @uncertain && @continuation_state == :resumed && !@execution_observation]
        end
        return unless ready
        execution_observer if needs_observation
        @mutex.synchronize do
          return if @attempts.active_snapshot_locked || (!resolved_locked? && !@terminal_transferred)
          @final_revision ||= @checkpoint&.fetch(:evidence)&.execution&.execution_revision
          @agent = @coordinator = @environment = @registry = @persistence = @preparer = nil
          @command = @request = @continuation_request = @checkpoint = @controls = @authority = @admission_participant = nil
          @admitted_execution = @filtered_input = @initial_session = nil
          @attempts.release_references_locked(nil)
          @original_error = @last_error = nil
          @original_waiters = []
        end
      end

      def unavailable(error)
        build_result(outcome: :unavailable, error: diagnostic(error || Phronomy::Error.new("Initial preparation remains unresolved")))
      end

      def diagnostic(error)
        @mutex.synchronize { diagnostic_locked(error) }
      end

      def diagnostic_locked(error)
        return error if error.is_a?(InitialPreparationRecoveryError) && error.recovery.equal?(recovery)
        InitialPreparationRecoveryError.new(recovery: recovery, error: error, original_error: @original_error || error)
      end

      def build_result(outcome: nil, error: nil)
        stage, confirmation, application, continuation, physical, checkpoint = @mutex.synchronize do
          [@stage, @confirmation, @application_state, @continuation_state,
            @attempts.quiescent_locked?, @checkpoint]
        end
        revision = if %i[confirmed_pre confirmed_post].include?(confirmation)
          evidence = checkpoint&.fetch(:evidence)
          (confirmation == :confirmed_post) ? (evidence&.execution&.execution_revision || @final_revision) : evidence&.before&.fetch(:execution)&.fetch("execution_revision", 0) || 0
        end
        task = execution_observer if %i[resumed stopped].include?(continuation)
        InitialPreparationRecoveryResult.new(recovery: recovery, stage: stage,
          outcome: confirmation || outcome || :unavailable, application_state: application,
          continuation_state: continuation, physical_complete: physical,
          revision: revision, execution_task: task, error: error)
      end
    end
  end
end
