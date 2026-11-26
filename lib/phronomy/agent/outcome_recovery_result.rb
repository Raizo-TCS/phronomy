# frozen_string_literal: true

module Phronomy
  module Agent
    # One immutable observation of a final-or-wait persistence obligation.
    # Releasing this recovery owner does not mean a waiting Agent job finished.
    # saved_outcome distinguishes a terminal result from coordination/approval
    # waits; error describes recovery rather than the saved business result.
    # @api public
    class OutcomeRecoveryResult
      OUTCOMES = %i[confirmed_post confirmed_pre unresolved unavailable].freeze
      SAVED_OUTCOMES = %i[terminal coordination_wait approval_wait].freeze
      APPLICATION_STATES = %i[pending applied].freeze
      OWNERSHIP_STATES = %i[retained released].freeze
      SUBMISSION_STATES = %i[not_admitted admitted unknown].freeze
      private_constant :OUTCOMES, :SAVED_OUTCOMES, :APPLICATION_STATES, :OWNERSHIP_STATES, :SUBMISSION_STATES

      # execution is present only for a terminal saved outcome. approval_request
      # is the exact saved wait request, not permission to bypass owner admission.
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id, :outcome,
        :saved_outcome, :application_state, :ownership_state, :revision,
        :execution, :approval_request, :error, :submission_state

      # @api private
      def initialize(recovery:, outcome:, application_state:, ownership_state:,
        saved_outcome: nil, revision: nil, execution: nil, approval_request: nil,
        error: nil, submission_state: :unknown)
        unless OUTCOMES.include?(outcome) && APPLICATION_STATES.include?(application_state) &&
            OWNERSHIP_STATES.include?(ownership_state) && SUBMISSION_STATES.include?(submission_state)
          raise ArgumentError, "unsupported Agent outcome recovery state"
        end
        if submission_state == :not_admitted && %i[confirmed_pre confirmed_post].include?(outcome)
          raise ArgumentError, "unadmitted Agent outcome work cannot have a captured persistence disposition"
        end
        if ownership_state == :released && application_state != :applied
          raise ArgumentError, "Agent recovery ownership cannot be released before application"
        end
        if outcome != :confirmed_post &&
            (application_state != :pending || ownership_state != :retained)
          raise ArgumentError, "Agent outcome work without confirmed post-state must remain pending and retained"
        end
        if outcome == :confirmed_post
          unless revision.is_a?(Integer) && revision.positive? && SAVED_OUTCOMES.include?(saved_outcome)
            raise ArgumentError, "confirmed Agent persistence requires its positive revision and saved outcome kind"
          end
          validate_saved_outcome!(recovery, saved_outcome, execution, approval_request)
        elsif !saved_outcome.nil? || !revision.nil? || !execution.nil? || !approval_request.nil?
          raise ArgumentError, "only confirmed Agent post-state has saved outcome values"
        end

        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @outcome = outcome
        @saved_outcome = saved_outcome
        @application_state = application_state
        @ownership_state = ownership_state
        @revision = revision
        @execution = execution
        @approval_request = approval_request
        @error = error
        @submission_state = submission_state
        freeze
      end

      private

      def validate_saved_outcome!(recovery, saved_outcome, execution, approval_request)
        if saved_outcome == :terminal
          unless execution.is_a?(ExecutionObservation) && execution.terminal? &&
              execution.agent_id == recovery.agent_id && execution.execution_id == recovery.execution_id &&
              approval_request.nil?
            raise ArgumentError, "terminal saved outcome requires its exact terminal execution observation"
          end
        elsif saved_outcome == :approval_wait
          unless execution.nil? && approval_request.is_a?(ToolApprovalRequest) &&
              approval_request.execution_id == recovery.execution_id
            raise ArgumentError, "approval wait requires its exact saved request and no terminal observation"
          end
        elsif !execution.nil? || !approval_request.nil?
          raise ArgumentError, "coordination wait has no terminal observation or approval request"
        end
      end
    end
  end
end
