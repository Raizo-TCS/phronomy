# frozen_string_literal: true

module Phronomy
  module Agent
    # Recovery observes responsibility already held by this Agent, including
    # during Runtime drain. It does not create a replacement owner or enter
    # ordinary new-execution admission.
    # @api private
    module DispatchRecoveryApi
      # Finds pre-dispatch work retained by this exact Agent incarnation.
      # Lookup performs no persistence I/O and creates no Runtime. Resolved work
      # leaves the index; an already held capability can return its final receipt.
      # @param execution_id [String] nonempty accepted execution identity
      # @return [DispatchRecovery, nil]
      # @api public
      def pending_dispatch_recovery(execution_id:)
        unless execution_id.is_a?(String) && !execution_id.empty?
          raise ArgumentError, "execution_id must be a nonempty String"
        end
        @_phronomy_runtime_owner&.existing_registry&.pending_agent_dispatch_recovery(execution_id, agent: self)
      end

      # Reads the retained barrier and applies confirmed post-state on its exact
      # owner. A positively established pre-barrier failure instead redelivers
      # only its retained setup-failure notification. Neither path repeats
      # provider/Tool work to infer its outcome or retries barrier writes.
      # Cancelling this observation does not cancel retained work or continuation.
      # @param recovery [DispatchRecovery] reference from this Agent
      # @return [TaskResult<DispatchRecoveryResult>] a fresh observation
      # @api public
      def reconcile_dispatch_async(recovery:)
        _dispatch_recovery_operation(recovery).observe(:reconcile)
      end

      # Waits for reconciliation on a host thread. The earlier failed execution
      # observation stays closed; a resumed receipt supplies a new observation.
      # @param recovery [DispatchRecovery] reference from this Agent
      # @return [DispatchRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def reconcile_dispatch(recovery:)
        _check_event_loop_reentrancy(:reconcile_dispatch, :reconcile_dispatch_async)
        reconcile_dispatch_async(recovery: recovery).wait_result
      end

      # Explicitly retries only the captured barrier writes after checking the
      # complete pre-state under the original Store guard and transaction.
      # Hooks, Policy, provider requests and Tool work are never replayed to
      # reconstruct a proposal. A positively established pre-barrier failure can
      # only redeliver its retained notification; other incomplete proposals stay
      # retained and pending.
      # @param recovery [DispatchRecovery] reference from this Agent
      # @return [TaskResult<DispatchRecoveryResult>] a fresh observation
      # @api public
      def retry_dispatch_async(recovery:)
        _dispatch_recovery_operation(recovery).observe(:retry)
      end

      # Waits for the explicit persistence-only retry on a host thread.
      # @param recovery [DispatchRecovery] reference from this Agent
      # @return [DispatchRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def retry_dispatch(recovery:)
        _check_event_loop_reentrancy(:retry_dispatch, :retry_dispatch_async)
        retry_dispatch_async(recovery: recovery).wait_result
      end

      private

      def _dispatch_recovery_operation(recovery)
        unless recovery.is_a?(DispatchRecovery)
          raise ArgumentError, "recovery must be an Agent::DispatchRecovery"
        end
        operation = recovery.send(:operation)
        unless operation.is_a?(DispatchRecoveryOperation) &&
            operation.recovery.equal?(recovery) && operation.belongs_to?(self)
          raise ArgumentError, "recovery belongs to another Agent incarnation"
        end
        operation
      end
    end
  end
end
