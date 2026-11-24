# frozen_string_literal: true

module Phronomy
  module Agent
    # Recovery observes responsibility already retained by this Agent, including
    # during Runtime drain. It does not enter ordinary execution admission or
    # create a replacement owner, Runtime or persistence authority.
    # @api private
    module ApprovalRecoveryApi
      # Finds uncertain approval work retained by this exact Agent incarnation.
      # This local lookup performs no persistence I/O and creates no Runtime.
      # Resolved work leaves the index; a held capability keeps its final receipt.
      # @param execution_id [String] nonempty accepted execution identity
      # @return [ApprovalRecovery, nil]
      # @api public
      def pending_approval_recovery(execution_id:)
        unless execution_id.is_a?(String) && !execution_id.empty?
          raise ArgumentError, "execution_id must be a nonempty String"
        end
        @_phronomy_runtime_owner&.existing_registry&.pending_agent_approval_recovery(execution_id, agent: self)
      end

      # Reads approval persistence and applies the confirmed state on its original
      # owner. A confirmed pre-state restores the same approval wait; a confirmed
      # post-state can start the first execution of the authorized continuation.
      # This does not retry approval writes. Cancelling the returned observation
      # does not cancel retained work or its continuation.
      # @param recovery [ApprovalRecovery] reference from this Agent
      # @return [TaskResult<ApprovalRecoveryResult>] a fresh observation
      # @api public
      def reconcile_approval_async(recovery:)
        _approval_recovery_operation(recovery).observe
      end

      # Waits for reconciliation on a host thread. The earlier failed approval
      # observation remains closed, even if recovery restores or resumes the job.
      # @param recovery [ApprovalRecovery] reference from this Agent
      # @return [ApprovalRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def reconcile_approval(recovery:)
        _check_event_loop_reentrancy(:reconcile_approval, :reconcile_approval_async)
        reconcile_approval_async(recovery: recovery).wait_result
      end

      private

      def _approval_recovery_operation(recovery)
        unless recovery.is_a?(ApprovalRecovery)
          raise ArgumentError, "recovery must be an Agent::ApprovalRecovery"
        end
        operation = recovery.send(:operation)
        unless operation.is_a?(ApprovalRecoveryOperation) &&
            operation.recovery.equal?(recovery) && operation.belongs_to?(self)
          raise ArgumentError, "recovery belongs to another Agent incarnation"
        end
        operation
      end
    end
  end
end
