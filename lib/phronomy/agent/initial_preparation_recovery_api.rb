# frozen_string_literal: true

module Phronomy
  module Agent
    # Recovers the initial request already held by this Agent's original owner.
    # Persistence confirmation, permitted first preparation and local handover
    # remain distinct from a new invocation or replay of earlier callbacks.
    # @api private
    module InitialPreparationRecoveryApi
      # Finds the one initial request retained by this exact Agent incarnation,
      # including a request whose durable admission has not been established.
      # Lookup performs no persistence I/O and creates no Runtime. Resolved work
      # leaves the index; an already held capability can return its final receipt.
      # @return [InitialPreparationRecovery, nil]
      # @api public
      def pending_initial_preparation_recovery
        @_phronomy_runtime_owner&.existing_registry&.pending_initial_preparation_recovery(agent: self)
      end

      # Classifies the captured stage and lets its original owner adopt confirmed
      # facts. It does not retry that stage's writes. Confirmed admission can run
      # preparation for the first time, including hooks, Policy and later initial
      # activation or failure saves; this method is not globally read-only.
      # Previously begun callbacks, Provider calls and Tool effects are not
      # replayed. Incomplete captured work remains unavailable for generic retry.
      # Cancelling this observation does not cancel the retained initial request.
      # @param recovery [InitialPreparationRecovery] reference from this Agent
      # @return [TaskResult<InitialPreparationRecoveryResult>] a fresh observation
      # @api public
      def reconcile_initial_preparation_async(recovery:)
        _initial_preparation_recovery_operation(recovery).observe(:reconcile)
      end

      # Waits for the initial recovery receipt on a host thread. The earlier
      # failed observation stays closed. A resolved receipt supplies a fresh
      # exact-execution observation, or a failed task for unadmitted work.
      # @param recovery [InitialPreparationRecovery] reference from this Agent
      # @return [InitialPreparationRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def reconcile_initial_preparation(recovery:)
        _check_event_loop_reentrancy(:reconcile_initial_preparation, :reconcile_initial_preparation_async)
        reconcile_initial_preparation_async(recovery: recovery).wait_result
      end

      # Authorizes retry of the current stage's exact captured writes after
      # guarded pre-state and ownership checks. A confirmed post-state is adopted
      # without rewriting it. Confirmed admission may then begin preparation for
      # the first time and save a later stage, as in reconciliation.
      # This is not permission to reconstruct an incomplete proposal, repeat
      # hooks or Policy, resubmit an uncertain worker, or repeat Provider/Tool work.
      # @param recovery [InitialPreparationRecovery] reference from this Agent
      # @return [TaskResult<InitialPreparationRecoveryResult>] a fresh observation
      # @api public
      def retry_initial_preparation_async(recovery:)
        _initial_preparation_recovery_operation(recovery).observe(:retry)
      end

      # Waits for the captured-stage retry and permitted handover receipt on a
      # host thread. Job completion is observed through the receipt's fresh task.
      # @param recovery [InitialPreparationRecovery] reference from this Agent
      # @return [InitialPreparationRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def retry_initial_preparation(recovery:)
        _check_event_loop_reentrancy(:retry_initial_preparation, :retry_initial_preparation_async)
        retry_initial_preparation_async(recovery: recovery).wait_result
      end

      private

      def _initial_preparation_recovery_operation(recovery)
        unless recovery.is_a?(InitialPreparationRecovery)
          raise ArgumentError, "recovery must be an Agent::InitialPreparationRecovery"
        end
        operation = recovery.send(:operation)
        unless operation.is_a?(InitialPreparationRecoveryOperation) &&
            operation.recovery.equal?(recovery) && operation.belongs_to?(self)
          raise ArgumentError, "recovery belongs to another Agent incarnation"
        end
        operation
      end
    end
  end
end
