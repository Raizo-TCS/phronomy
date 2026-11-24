# frozen_string_literal: true

module Phronomy
  module Agent
    # Recovery addresses retained responsibility, including during Runtime drain.
    # These observations do not enter ordinary new-execution admission or create
    # a coordinator, Runtime, replacement Agent or persistence authority.
    # @api private
    module TerminalRecoveryApi
      # Finds uncertain terminal work retained by this exact Agent incarnation.
      # This local lookup performs no persistence I/O and creates no Runtime.
      # Resolved work leaves the index; a held capability keeps its final receipt.
      # @param execution_id [String] nonempty accepted execution identity
      # @return [TerminalRecovery, nil]
      # @api public
      def pending_terminal_recovery(execution_id:)
        unless execution_id.is_a?(String) && !execution_id.empty?
          raise ArgumentError, "execution_id must be a nonempty String"
        end
        @_phronomy_runtime_owner&.existing_registry&.pending_agent_terminal_recovery(execution_id, agent: self)
      end

      # Classifies terminal persistence and applies a confirmed post-state on
      # the exact original owner. It never retries writes or business actions.
      # Cancelling the returned observation does not cancel retained work.
      # @param recovery [TerminalRecovery] reference from this Agent
      # @return [TaskResult<TerminalRecoveryResult>] a fresh observation
      # @api public
      def reconcile_terminal_async(recovery:)
        _terminal_recovery_operation(recovery).observe(:reconcile)
      end

      # Waits for reconciliation on a host thread. An earlier failed or cancelled
      # observation is never reopened, even after recovery succeeds.
      # @param recovery [TerminalRecovery] reference from this Agent
      # @return [TerminalRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def reconcile_terminal(recovery:)
        _check_event_loop_reentrancy(:reconcile_terminal, :reconcile_terminal_async)
        reconcile_terminal_async(recovery: recovery).wait_result
      end

      # Explicitly retries only captured terminal persistence writes. The full
      # pre-state is rechecked under the original Store guard and transaction.
      # Provider, Tool, parser, encoder and business callbacks are not replayed.
      # @param recovery [TerminalRecovery] reference from this Agent
      # @return [TaskResult<TerminalRecoveryResult>] a fresh observation
      # @api public
      def retry_terminal_async(recovery:)
        _terminal_recovery_operation(recovery).observe(:retry)
      end

      # Waits for the explicit persistence-only retry on a host thread.
      # @param recovery [TerminalRecovery] reference from this Agent
      # @return [TerminalRecoveryResult]
      # @raise [EventLoopReentrancyError] when called on EventLoop
      # @api public
      def retry_terminal(recovery:)
        _check_event_loop_reentrancy(:retry_terminal, :retry_terminal_async)
        retry_terminal_async(recovery: recovery).wait_result
      end

      private

      def _terminal_recovery_operation(recovery)
        unless recovery.is_a?(TerminalRecovery)
          raise ArgumentError, "recovery must be an Agent::TerminalRecovery"
        end
        operation = recovery.send(:operation)
        unless operation.is_a?(TerminalRecoveryOperation) &&
            operation.recovery.equal?(recovery) && operation.belongs_to?(self)
          raise ArgumentError, "recovery belongs to another Agent incarnation"
        end
        operation
      end
    end
  end
end
