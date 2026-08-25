# frozen_string_literal: true

require_relative "recovery_support"

module Phronomy
  module Agent
    # Durable Agent Recovery owner/resolver.
    #
    # This class owns Agent-specific restart hydration and factual resolution.
    # Shared Recovery semantics remain in Phronomy::Recovery.
    # @api private
    class RecoveryCoordinator
      class ResolutionOutcomeUnknownError < Phronomy::Error
        attr_reader :original_error, :intended_result

        def initialize(original_error, intended_result)
          @original_error = original_error
          @intended_result = intended_result
          super(
            "Recovery resolution Persistence outcome is unknown: " + "#{original_error.class}: #{original_error.message}"
          )
          set_backtrace(original_error.backtrace)
        end
      end
      private_constant :ResolutionOutcomeUnknownError

      InstallCommand = Data.define(
        :coordinator, :plan, :completion, :owner_token
      )
      ResolveCommand = Data.define(
        :coordinator, :execution_id, :expected_execution_revision,
        :subject, :outcome, :result, :failure, :completion
      )
      ResolveReady = Data.define(
        :coordinator, :request, :operation, :result, :error
      )
      ResolutionOperation = Data.define(
        :execution, :root, :subject, :outcome, :result, :failure
      )
      ResolutionResult = Data.define(
        :execution, :root, :continuation, :failure, :appended_records
      )
      RecoveryPlan = Data.define(
        :execution, :root, :manifest, :base_manifest,
        :projection, :classification
      )

      attr_reader :agent

      def initialize(agent)
        @agent = agent
      end

      def recover_on_load!
        active = agent.persistence.transaction do |tx|
          Array(tx.executions.list_active(agent.agent_id))
        end
        if active.length > 1
          raise Phronomy::Persistence::ConflictError,
            "multiple active AgentExecutions exist for #{agent.agent_id}"
        end
        return agent if active.empty?

        execution = active.first
        unless execution.agent_id.to_s == agent.agent_id.to_s
          raise Phronomy::Persistence::ConflictError,
            "active AgentExecution belongs to another Agent: #{execution.agent_id}"
        end

        plan = prepare_plan(execution)
        classification = plan.classification
        if classification.disposition ==
            Phronomy::Recovery::RESOLUTION_REQUIRED &&
            !agent.send(:_phronomy_event_listener)
          raise Phronomy::ConfigurationError,
            "Agent #{agent.agent_id.inspect} requires Recovery resolution; " \
            "load must register on_event"
        end
        if execution.status == :suspended &&
            !agent.send(:_phronomy_event_listener)
          raise Phronomy::ConfigurationError,
            "Agent #{agent.agent_id.inspect} has a pending approval; " \
            "load must register on_event"
        end

        completion = Phronomy::Task.deferred(
          name: "agent-recovery-load:#{execution.execution_id}"
        )
        command = InstallCommand.new(
          coordinator: self,
          plan: plan,
          completion: completion,
          owner_token: Object.new.freeze
        )
        unless post_control(command)
          completion.fail(
            Phronomy::RuntimeShutdownError.new(
              "EventLoop rejected Agent Recovery installation"
            )
          )
        end
        completion.wait_result
        agent
      end

      def resolve(
        execution_id,
        expected_execution_revision:,
        subject:,
        outcome:,
        result: Phronomy::Recovery::MISSING,
        error: Phronomy::Recovery::MISSING
      )
        agent.send(:__assert_live_agent!)
        normalized_outcome = Phronomy::Recovery.normalize_outcome(outcome)
        result_present = !result.equal?(Phronomy::Recovery::MISSING)
        error_present = !error.equal?(Phronomy::Recovery::MISSING)
        Phronomy::Recovery.validate_resolution_material!(
          outcome: normalized_outcome,
          result_present: result_present,
          error_present: error_present
        )

        normalized_subject =
          Phronomy::Recovery.normalize_subject(subject)
        canonical_result = if result_present
          if normalized_subject[:type] == :llm_call &&
              normalized_outcome == :succeeded
            RecoverySupport.normalize_provider_outcome(result).to_h
          else
            RecoverySupport.canonical_copy(result)
          end
        end
        failure = error_present ?
          RecoverySupport.resolution_failure(error) : nil

        completion = Phronomy::Task.deferred(
          name: "agent-recovery-resolve:#{execution_id}"
        )
        command = ResolveCommand.new(
          coordinator: self,
          execution_id: execution_id.to_s.freeze,
          expected_execution_revision:
            Integer(expected_execution_revision),
          subject: normalized_subject,
          outcome: normalized_outcome,
          result: canonical_result,
          failure: failure,
          completion: completion
        )
        unless post_control(command)
          completion.fail(
            Phronomy::RuntimeShutdownError.new(
              "EventLoop rejected Agent Recovery resolution"
            )
          )
        end
        completion
      rescue => caught
        completion ||= Phronomy::Task.deferred(
          name: "agent-recovery-resolve:#{execution_id}"
        )
        completion.fail(caught)
        completion
      end

      def deliver_on_event_loop(command)
        case command
        when InstallCommand
          install_on_event_loop(command)
        when ResolveCommand
          begin_resolve_on_event_loop(command)
        when ResolveReady
          apply_resolve_on_event_loop(command)
        else
          raise Phronomy::Error,
            "unknown Recovery control command: #{command.class}"
        end
      end

      private

      def post_control(command)
        Phronomy::Runtime.instance.event_loop.post(
          Phronomy::Event.new(
            type: :agent_control,
            target_id:
              Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {command: command}.freeze
          )
        )
      rescue Phronomy::RuntimeShutdownError
        false
      end
    end
  end
end

require_relative "recovery_coordinator/installation"
require_relative "recovery_coordinator/resolution"
require_relative "recovery_coordinator/continuation"

module Phronomy
  module Agent
    class RecoveryCoordinator
      include Installation
      include Resolution
      include Continuation
    end
  end
end
