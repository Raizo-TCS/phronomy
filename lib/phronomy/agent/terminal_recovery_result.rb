# frozen_string_literal: true

module Phronomy
  module Agent
    # One observation of persistence, original-owner application and release.
    # The saved execution's failure is in execution.error; error describes the
    # recovery operation itself. A confirmed pre-state retains the active job.
    # @api public
    class TerminalRecoveryResult
      OUTCOMES = %i[confirmed_post confirmed_pre unresolved unavailable].freeze
      APPLICATION_STATES = %i[pending applied].freeze
      OWNERSHIP_STATES = %i[retained released].freeze
      private_constant :OUTCOMES, :APPLICATION_STATES, :OWNERSHIP_STATES

      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id, :outcome,
        :application_state, :ownership_state, :revision, :execution, :error

      # @api private
      def initialize(recovery:, outcome:, application_state:, ownership_state:,
        revision: nil, execution: nil, error: nil)
        unless OUTCOMES.include?(outcome) && APPLICATION_STATES.include?(application_state) &&
            OWNERSHIP_STATES.include?(ownership_state)
          raise ArgumentError, "unsupported Agent terminal recovery state"
        end
        if ownership_state == :released && application_state != :applied
          raise ArgumentError, "Agent ownership cannot be released before application"
        end
        if outcome != :confirmed_post &&
            (application_state != :pending || ownership_state != :retained)
          raise ArgumentError, "Agent terminal work without confirmed post-state must remain pending and retained"
        end
        if outcome == :confirmed_post
          unless revision.is_a?(Integer) && revision.positive?
            raise ArgumentError, "confirmed Agent persistence requires its positive execution revision"
          end
          if execution && (!execution.is_a?(ExecutionObservation) || !execution.terminal? ||
              execution.agent_id != recovery.agent_id || execution.execution_id != recovery.execution_id)
            raise ArgumentError, "confirmed Agent execution must match the recovery reference"
          end
        elsif !revision.nil? || !execution.nil?
          raise ArgumentError, "only confirmed Agent post-state has a revision or execution"
        end

        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @outcome = outcome
        @application_state = application_state
        @ownership_state = ownership_state
        @revision = revision
        @execution = execution
        @error = error
        freeze
      end
    end
  end
end
