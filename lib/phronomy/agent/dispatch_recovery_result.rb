# frozen_string_literal: true

module Phronomy
  module Agent
    # One immutable observation of pre-dispatch persistence and continuation.
    # error describes recovery; execution_task observes the job's actual result.
    # Resolving this obligation neither proves job success nor releases the job.
    # @api public
    class DispatchRecoveryResult
      OUTCOMES = %i[confirmed_pre confirmed_post not_prepared unresolved unavailable].freeze
      APPLICATION_STATES = %i[pending applied].freeze
      CONTINUATION_STATES = %i[pending resumed stopped].freeze
      private_constant :OUTCOMES, :APPLICATION_STATES, :CONTINUATION_STATES

      # revision describes the captured barrier's confirmed record. An execution
      # observation is fresh for each receipt, never the owner's canonical task.
      # @api public
      attr_reader :recovery, :agent_id, :execution_id, :recovery_id, :dispatch_kind,
        :outcome, :application_state, :continuation_state, :revision, :execution_task, :error

      # @api private
      def initialize(recovery:, outcome:, application_state:, continuation_state:,
        physical_complete:, revision: nil, execution_task: nil, error: nil)
        unless OUTCOMES.include?(outcome) && APPLICATION_STATES.include?(application_state) &&
            CONTINUATION_STATES.include?(continuation_state)
          raise ArgumentError, "unsupported Agent dispatch recovery state"
        end
        unless physical_complete.equal?(true) || physical_complete.equal?(false)
          raise ArgumentError, "dispatch physical completion must be a boolean"
        end
        if %i[confirmed_pre confirmed_post].include?(outcome)
          unless revision.is_a?(Integer) && revision >= 0
            raise ArgumentError, "confirmed dispatch persistence requires its nonnegative execution revision"
          end
        elsif !revision.nil?
          raise ArgumentError, "unclassified or unprepared dispatch work has no confirmed revision"
        end
        case outcome
        when :confirmed_post
          if continuation_state == :stopped
            raise ArgumentError, "only positively unprepared dispatch work can use stopped continuation"
          end
        when :not_prepared
          if continuation_state == :resumed
            raise ArgumentError, "unprepared dispatch work cannot resume a barrier"
          end
        else
          if application_state != :pending || continuation_state != :pending
            raise ArgumentError, "dispatch work without confirmed post-state must remain pending"
          end
        end
        if %i[resumed stopped].include?(continuation_state)
          unless application_state == :applied && physical_complete && execution_task.is_a?(Phronomy::TaskResult)
            raise ArgumentError, "dispatch continuation requires application, physical completion and an execution observation"
          end
        elsif !execution_task.nil?
          raise ArgumentError, "only resumed or stopped dispatch work has an execution observation"
        end

        @recovery = recovery
        @agent_id = recovery.agent_id.to_s.dup.freeze
        @execution_id = recovery.execution_id.to_s.dup.freeze
        @recovery_id = recovery.recovery_id.to_s.dup.freeze
        @dispatch_kind = recovery.dispatch_kind
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
      # The continued provider, Tool or overall Agent execution may still run.
      # @return [Boolean]
      # @api public
      def physical_complete?
        @physical_complete
      end

      # True after the exact owner handed off the confirmed barrier continuation,
      # or its positively established pre-barrier failure notification. Stopped
      # never permits preparation replay; execution_task observes the job result.
      # @return [Boolean]
      # @api public
      def resolved?
        @physical_complete && @application_state == :applied && %i[resumed stopped].include?(@continuation_state)
      end
    end
  end
end
