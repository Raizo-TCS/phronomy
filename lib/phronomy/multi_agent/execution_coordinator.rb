# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Handoff-aware specialization of the normal Agent execution coordinator.
    # It changes only the terminal semantics of an invocation that produced a
    # typed HandoffRequest; preparation, ordinary completion, failure, Tool and
    # approval behavior remain owned by Agent::ExecutionCoordinator.
    class ExecutionCoordinator < Phronomy::Agent::ExecutionCoordinator
      private

      def compute_terminal(activation, invocation, error)
        if (failure = activation.callback_failure)
          terminal = commit_failed(
            activation,
            invocation,
            failure.to_stream_callback_error
          )
          return {type: :failed, error: terminal.fetch(:error)}
        end
        if error
          terminal = commit_failed(activation, invocation, error)
          return {type: :failed, error: terminal.fetch(:error)}
        end
        if invocation&.phase == :suspended
          return {
            type: :suspended,
            result: commit_suspended(activation, invocation)
          }
        end
        raise invocation.block_error if invocation.input_blocked? || invocation.output_blocked?
        raise invocation.error if invocation.error

        if invocation.handoff_requested?
          return {
            type: :handed_off,
            result: commit_handed_off(activation, invocation)
          }
        end

        {type: :completed, result: commit_completed(activation, invocation)}
      rescue => caught
        terminal = commit_failed(activation, invocation, caught)
        {type: :failed, error: terminal.fetch(:error)}
      end

      def commit_handed_off(activation, invocation)
        current = activation.execution
        root = @agent.agent_root
        runtime_snapshot = activation.runtime_snapshot
        request = invocation.handoff_request
        handed_off = next_root = appended = nil

        @agent.persistence.transaction do |tx|
          # The terminal Provider outcome contains the internal Handoff Tool Call.
          # Preserve it in the complete execution log, but do not make it a future
          # Context candidate. Earlier Provider/Tool cycles are already present in
          # current.working_records with their normal Context eligibility.
          encoded_records, call_records = encode_runtime_records(
            activation,
            tx: tx,
            snapshot: runtime_snapshot,
            context_candidate: false,
            agent_root: root
          )
          audit_ref = tx.contents.put_json(
            "target_agent_id" => request.handoff.target_agent.agent_id,
            "responsibility" => request.responsibility,
            "selection_intent" => request.selection_intent.to_h do |category, included|
              [category.to_s, included]
            end
          )
          audit_record = Phronomy::Agent::JournalRecord.new(
            agent_id: @agent.agent_id,
            execution_id: current.execution_id,
            llm_call_id: request.llm_call_id,
            kind: :execution_handed_off,
            channel: :audit,
            content_ref: audit_ref,
            context_generation: root.transcript_generation,
            context_candidate: false,
            metadata: {
              "target_agent_id" => request.handoff.target_agent.agent_id,
              "handoff_tool_call_id" => request.tool_call_id
            }.compact
          )

          all_records = current.working_records + encoded_records + [audit_record]
          appended = tx.journals.append(
            root.agent_id,
            expected_position: root.journal_position,
            records: all_records
          )
          handed_off = current.with(
            status: :handed_off,
            phase: :handed_off,
            working_records: [],
            llm_calls: current.llm_calls + call_records,
            approval_request: nil,
            terminal_reason: "handed_off"
          )
          tx.executions.save(
            current.execution_id,
            expected_revision: current.execution_revision,
            execution: handed_off
          )
          context_changed = appended.any?(&:context_candidate)
          next_root = root.with(
            agent_revision: root.agent_revision + 1,
            context_revision: root.context_revision + (context_changed ? 1 : 0),
            journal_position: root.journal_position + appended.length,
            lifecycle_status: :idle
          )
          tx.agents.save(
            root.agent_id,
            expected_revision: root.agent_revision,
            root: next_root
          )
        end

        activation.acknowledge_runtime_snapshot(runtime_snapshot)
        activation.replace_execution(handed_off)
        @agent.send(:_append_journal_records, appended)
        @agent.__replace_root(next_root)

        result_base(handed_off, next_root).merge(
          handoff_request: request,
          _phronomy_handoff_manifest: activation.runtime_projection.manifest
        )
      end

      def deliver_execution_terminal(command)
        activation = command.activation
        registry = Phronomy::Runtime.instance.__agent_activations
        if command.commit_error
          callback_error = deliver_terminal(
            activation,
            :error,
            error: command.commit_error
          )
          settle_after_terminal(
            command.result_task,
            callback_error,
            :error,
            nil,
            command.commit_error
          )
          return
        end

        outcome = command.outcome
        case outcome.fetch(:type)
        when :suspended
          result = outcome.fetch(:result)
          callback_error = deliver_terminal(
            activation,
            :approval_required,
            request: result.fetch(:approval_request)
          )
          settle_after_terminal(
            command.result_task,
            callback_error,
            :approval_required,
            result
          )
        when :handed_off
          registry.delete(activation.execution_id)
          result = outcome.fetch(:result)
          callback_error = deliver_terminal(activation, :handoff, result)
          settle_after_terminal(
            command.result_task,
            callback_error,
            :handoff,
            result
          )
        when :completed
          registry.delete(activation.execution_id)
          result = outcome.fetch(:result)
          callback_error = deliver_terminal(activation, :done, result)
          settle_after_terminal(
            command.result_task,
            callback_error,
            :done,
            result
          )
        when :failed
          registry.delete(activation.execution_id)
          error = outcome.fetch(:error)
          type = terminal_event_type(error)
          callback_error = deliver_terminal(activation, type, error: error)
          settle_after_terminal(
            command.result_task,
            callback_error,
            type,
            nil,
            error
          )
        end
      end

      def settle_without_listener(activation, result_task, outcome, commit_error)
        registry = Phronomy::Runtime.instance.__agent_activations
        return fail_task(result_task, commit_error) if commit_error

        case outcome&.fetch(:type)
        when :suspended
          complete_task(result_task, outcome.fetch(:result))
        when :handed_off, :completed
          registry.delete(activation.execution_id)
          complete_task(result_task, outcome.fetch(:result))
        when :failed
          registry.delete(activation.execution_id)
          fail_task(result_task, outcome.fetch(:error))
        else
          registry.delete(activation.execution_id)
          fail_task(
            result_task,
            Phronomy::RuntimeShutdownError.new(
              "EventLoop is not accepting terminal delivery"
            )
          )
        end
      end
    end
  end
end
