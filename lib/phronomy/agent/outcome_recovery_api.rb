# frozen_string_literal: true

module Phronomy
  module Agent
    # Recovery addresses retained responsibility, including during Runtime drain.
    # These observations do not enter ordinary new-execution admission or create
    # a coordinator, Runtime, replacement Agent or persistence authority.
    # @api private
    module OutcomeRecoveryApi
      # Finds uncertain outcome work retained by this exact Agent incarnation.
      # This local lookup performs no persistence I/O and creates no Runtime.
      # Resolved recovery leaves the index; a held capability keeps its receipt.
      # A saved wait can resolve recovery while the Agent execution remains open.
      # @param execution_id [String] nonempty accepted execution identity
      # @return [OutcomeRecovery, nil]
      # @api public
      def pending_outcome_recovery(execution_id:)
        unless execution_id.is_a?(String) && !execution_id.empty?
          raise ArgumentError, "execution_id must be a nonempty String"
        end
        @_phronomy_runtime_owner&.existing_registry&.pending_agent_outcome_recovery(execution_id, agent: self)
      end

      # Classifies final or waiting persistence and applies its saved kind on
      # the exact original owner. It never retries writes or business actions.
      # Cancelling the returned observation does not cancel retained work.
      # @param recovery [OutcomeRecovery] reference from this Agent
      # @return [TaskResult<OutcomeRecoveryResult>] a fresh observation
      # @api public
      def reconcile_outcome_async(recovery:)
        _outcome_recovery_operation(recovery).observe(:reconcile)
      end

      # Waits for reconciliation on a host thread. An earlier failed or cancelled
      # observation is never reopened, even after recovery succeeds.
      # @param recovery [OutcomeRecovery] reference from this Agent
      # @return [OutcomeRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def reconcile_outcome(recovery:)
        _check_event_loop_reentrancy(:reconcile_outcome, :reconcile_outcome_async)
        reconcile_outcome_async(recovery: recovery).wait_result
      end

      # Explicitly retries only captured outcome persistence writes. The full
      # pre-state is rechecked under the original Store guard and transaction.
      # Provider, Tool, parser, encoder and business callbacks are not replayed.
      # @param recovery [OutcomeRecovery] reference from this Agent
      # @return [TaskResult<OutcomeRecoveryResult>] a fresh observation
      # @api public
      def retry_outcome_async(recovery:)
        _outcome_recovery_operation(recovery).observe(:retry)
      end

      # Waits for the explicit persistence-only retry on a host thread.
      # @param recovery [OutcomeRecovery] reference from this Agent
      # @return [OutcomeRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def retry_outcome(recovery:)
        _check_event_loop_reentrancy(:retry_outcome, :retry_outcome_async)
        retry_outcome_async(recovery: recovery).wait_result
      end

      # Explicitly resubmits outcome work only after the original execution
      # mechanism proved it was not admitted and no handle or worker started.
      # Validation and encoding may run for the first time; provider and Tool
      # work are not repeated. This never broadens captured-write retry.
      # @param recovery [OutcomeRecovery] reference from this Agent
      # @return [TaskResult<OutcomeRecoveryResult>] a fresh observation
      # @api public
      def retry_outcome_submission_async(recovery:)
        _outcome_recovery_operation(recovery).observe(:submission)
      end

      # Waits for the explicit first outcome-work submission on a host thread.
      # A previous not_admitted receipt is a fact, not a reusable permission.
      # @param recovery [OutcomeRecovery] reference from this Agent
      # @return [OutcomeRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def retry_outcome_submission(recovery:)
        _check_event_loop_reentrancy(:retry_outcome_submission, :retry_outcome_submission_async)
        retry_outcome_submission_async(recovery: recovery).wait_result
      end

      private

      def _outcome_recovery_operation(recovery)
        unless recovery.is_a?(OutcomeRecovery)
          raise ArgumentError, "recovery must be an Agent::OutcomeRecovery"
        end
        operation = recovery.send(:operation)
        unless operation.is_a?(OutcomeRecoveryOperation) && operation.recovery_kind == :outcome &&
            operation.recovery.equal?(recovery) && operation.belongs_to?(self)
          raise ArgumentError, "recovery belongs to another Agent incarnation"
        end
        operation
      end
    end
  end
end
