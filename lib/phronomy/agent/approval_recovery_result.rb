# frozen_string_literal: true

module Phronomy
  module Agent
    # One immutable observation of an approval decision and its continuation.
    # Restoring a wait or resuming approved work does not release the Agent job.
    # error describes recovery; execution_task separately observes resumed work.
    # @api public
    class ApprovalRecoveryResult
      OUTCOMES = %i[confirmed_pre confirmed_post unresolved unavailable].freeze
      APPLICATION_STATES = %i[pending applied].freeze
      CONTINUATION_STATES = %i[pending restored resumed].freeze
      private_constant :OUTCOMES, :APPLICATION_STATES, :CONTINUATION_STATES

      # revision identifies the confirmed execution record: the original wait
      # revision for pre-state, or the saved approval revision for post-state.
      # execution_task is a fresh observation, never the owner's canonical task.
      # hosted_invocation has its own observation and exact next-wait detach
      # authority. It is nil once that hosted authority has physically finished.
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :approval_request_id, :recovery_id,
        :approved, :outcome, :application_state, :continuation_state, :revision,
        :execution_task, :hosted_invocation, :error

      # @api private
      def initialize(recovery:, outcome:, application_state:, continuation_state:,
        physical_complete:, revision: nil, execution_task: nil, hosted_invocation: nil, error: nil)
        unless OUTCOMES.include?(outcome) && APPLICATION_STATES.include?(application_state) &&
            CONTINUATION_STATES.include?(continuation_state)
          raise ArgumentError, "unsupported Agent approval recovery state"
        end
        unless physical_complete.equal?(true) || physical_complete.equal?(false)
          raise ArgumentError, "approval physical completion must be a boolean"
        end
        if %i[confirmed_pre confirmed_post].include?(outcome)
          unless revision.is_a?(Integer) && revision >= 0
            raise ArgumentError, "confirmed approval persistence requires its nonnegative execution revision"
          end
        elsif !revision.nil? || application_state != :pending || continuation_state != :pending
          raise ArgumentError, "unclassified approval work must remain pending without a revision"
        end
        if continuation_state != :pending && (application_state != :applied || !physical_complete)
          raise ArgumentError, "approval continuation requires application and physical completion"
        end
        if continuation_state == :restored && outcome != :confirmed_pre
          raise ArgumentError, "only confirmed approval pre-state can restore the wait"
        end
        if continuation_state == :resumed
          unless outcome == :confirmed_post && execution_task.is_a?(Phronomy::TaskResult)
            raise ArgumentError, "resumed approval requires confirmed post-state and an execution observation"
          end
        elsif !execution_task.nil?
          raise ArgumentError, "only resumed approval work has an execution observation"
        end
        if !hosted_invocation.nil? &&
            (continuation_state != :resumed || !hosted_invocation.is_a?(HostedInvocation))
          raise ArgumentError, "only resumed hosted approval work has a hosted invocation"
        end

        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @approval_request_id = recovery.approval_request_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @approved = recovery.approved
        @outcome = outcome
        @application_state = application_state
        @continuation_state = continuation_state
        @physical_complete = physical_complete
        @revision = revision
        @execution_task = execution_task
        @hosted_invocation = hosted_invocation
        @error = error
        freeze
      end

      # True only when the approval save and recovery read workers have stopped.
      # The resumed Tool, provider or overall Agent execution can still be active.
      # @return [Boolean]
      # @api public
      def physical_complete?
        @physical_complete
      end

      # True when the owner applied the proof and restored the same approval wait
      # or resumed its continuation. The execution itself need not be terminal.
      # @return [Boolean]
      # @api public
      def resolved?
        @physical_complete && @application_state == :applied && %i[restored resumed].include?(@continuation_state)
      end
    end
  end
end
