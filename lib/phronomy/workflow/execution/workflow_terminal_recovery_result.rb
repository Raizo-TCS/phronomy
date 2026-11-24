# frozen_string_literal: true

module Phronomy
  # One immutable observation of terminal persistence, owner application and
  # ownership release. Confirmed persistence alone is not completed recovery.
  # The context is an independent application view, not retained proof.
  # @api public
  class WorkflowTerminalRecoveryResult
    OUTCOMES = %i[confirmed_post confirmed_pre unresolved unavailable].freeze
    APPLICATION_STATES = %i[pending applied].freeze
    OWNERSHIP_STATES = %i[retained released].freeze
    private_constant :OUTCOMES, :APPLICATION_STATES, :OWNERSHIP_STATES

    # @api public
    attr_reader :recovery, :workflow_instance_id, :recovery_id, :outcome,
      :application_state, :ownership_state, :revision, :context, :error

    # Constructed from facts retained by the exact Workflow owner.
    # @api private
    def initialize(recovery:, outcome:, application_state:, ownership_state:,
      revision: nil, context: nil, error: nil)
      unless OUTCOMES.include?(outcome) && APPLICATION_STATES.include?(application_state) &&
          OWNERSHIP_STATES.include?(ownership_state)
        raise ArgumentError, "unsupported Workflow terminal recovery state"
      end
      if ownership_state == :released && application_state != :applied
        raise ArgumentError, "Workflow ownership cannot be released before application"
      end
      if %i[unresolved unavailable].include?(outcome) &&
          (application_state != :pending || ownership_state != :retained)
        raise ArgumentError, "unclassified Workflow persistence must remain pending and retained"
      end
      if outcome == :confirmed_post
        unless revision.is_a?(Integer) && revision.positive?
          raise ArgumentError, "confirmed Workflow persistence requires its positive revision"
        end
      elsif !revision.nil? || !context.nil?
        raise ArgumentError, "only confirmed Workflow post-state has a revision or context"
      end

      @recovery = recovery
      @workflow_instance_id = recovery.workflow_instance_id.to_s.dup.freeze
      @recovery_id = recovery.recovery_id.to_s.dup.freeze
      @outcome = outcome
      @application_state = application_state
      @ownership_state = ownership_state
      @revision = revision
      @context = context
      @error = error
      freeze
    end
  end
end
