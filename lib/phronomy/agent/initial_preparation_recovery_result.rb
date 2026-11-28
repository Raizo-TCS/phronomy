# frozen_string_literal: true

module Phronomy
  module Agent
    # One immutable observation of an initial stage and its original handover.
    # error describes recovery, not a failed job. A resolved receipt supplies a
    # fresh exact-execution task; its saved failed/cancelled status is a fulfilled
    # result. Unadmitted work instead supplies a failed observation task.
    # @api public
    class InitialPreparationRecoveryResult
      OUTCOMES = %i[confirmed_pre confirmed_post not_prepared unresolved unavailable].freeze
      APPLICATION_STATES = %i[pending applied].freeze
      CONTINUATION_STATES = %i[pending resumed stopped].freeze
      STAGES = %i[admission activation failure].freeze
      private_constant :OUTCOMES, :APPLICATION_STATES, :CONTINUATION_STATES, :STAGES

      # revision is the saved revision for confirmed_post and the preceding
      # revision for confirmed_pre. Admission uses zero for both; confirmed_pre
      # then proves exact absence, not an existing revision-zero record.
      # An unclassified or not_prepared receipt has no confirmed revision.
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id, :stage,
        :outcome, :application_state, :continuation_state, :revision, :execution_task, :error

      # @api private
      def initialize(recovery:, outcome:, application_state:, continuation_state:,
        physical_complete:, stage:, revision: nil, execution_task: nil, error: nil)
        unless recovery.is_a?(InitialPreparationRecovery)
          raise ArgumentError, "recovery must be an Agent::InitialPreparationRecovery"
        end
        unless error.nil? || error.is_a?(Exception)
          raise ArgumentError, "initial preparation recovery error must be an exception or nil"
        end
        unless OUTCOMES.include?(outcome) && APPLICATION_STATES.include?(application_state) &&
            CONTINUATION_STATES.include?(continuation_state) && STAGES.include?(stage)
          raise ArgumentError, "unsupported Agent initial preparation recovery state"
        end
        unless physical_complete.equal?(true) || physical_complete.equal?(false)
          raise ArgumentError, "initial preparation physical completion must be a boolean"
        end
        if %i[confirmed_pre confirmed_post].include?(outcome)
          unless revision.is_a?(Integer) && revision >= 0
            raise ArgumentError, "confirmed initial preparation persistence requires its nonnegative execution revision"
          end
          if stage == :admission && revision != 0
            raise ArgumentError, "confirmed initial admission uses revision zero"
          end
          if stage != :admission && outcome == :confirmed_post && revision.zero?
            raise ArgumentError, "confirmed activation or failure requires an advanced execution revision"
          end
        elsif !revision.nil?
          raise ArgumentError, "unclassified or unprepared initial preparation work has no confirmed revision"
        end
        if outcome == :not_prepared && stage != :admission
          raise ArgumentError, "only initial admission can be positively unprepared"
        end
        stopped_before_admission = outcome == :confirmed_pre && stage == :admission && continuation_state == :stopped
        unless %i[confirmed_post not_prepared].include?(outcome) || stopped_before_admission
          if application_state != :pending || continuation_state != :pending
            raise ArgumentError, "unconfirmed initial preparation must remain pending"
          end
        end
        if %i[resumed stopped].include?(continuation_state)
          allowed = if continuation_state == :resumed
            outcome == :confirmed_post && stage == :activation
          else
            (outcome == :confirmed_post && stage == :failure) ||
              (%i[confirmed_pre not_prepared].include?(outcome) && stage == :admission)
          end
          unless allowed
            raise ArgumentError, "initial preparation continuation contradicts its confirmed stage"
          end
          unless application_state == :applied && physical_complete && execution_task.is_a?(Phronomy::TaskResult)
            raise ArgumentError, "initial preparation continuation requires application, physical completion and an execution observation"
          end
        elsif !execution_task.nil?
          raise ArgumentError, "only resumed or stopped initial preparation work has an execution observation"
        end

        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @stage = stage
        @outcome = outcome
        @application_state = application_state
        @continuation_state = continuation_state
        @physical_complete = physical_complete
        @revision = revision
        @execution_task = execution_task
        @error = error
        freeze
      end

      # True only after the original preparation and recovery workers stopped.
      # Continued Provider/Tool work and the overall Agent job may still run.
      # @return [Boolean]
      # @api public
      def physical_complete?
        @physical_complete
      end

      # True after confirmed activation was handed to the execution owner, or
      # confirmed failure/unadmitted work was handed to its stopped observation.
      # Cancelled admission with confirmed pre-state stops without creating a job.
      # Admission confirmation alone is unresolved. Resolution does not imply
      # successful job completion or permit preparation to be replayed.
      # @return [Boolean]
      # @api public
      def resolved?
        @physical_complete && @application_state == :applied && %i[resumed stopped].include?(@continuation_state)
      end
    end
  end
end
