# frozen_string_literal: true

module Phronomy
  # ACS-15 Workflow-side Persistence F1 reconciliation. Workflow hydration and
  # orchestration remain owned by WorkflowRunner; this module only replaces the
  # terminal durable barrier so response loss is reconciled from authoritative
  # durable pre/post state instead of being treated as an ordinary failed save.
  # @api private
  module WorkflowRecovery
    private

    def begin_terminal_persistence_on_event_loop(
      execution,
      terminal_type:,
      context:,
      event_sink:
    )
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      assert_event_loop!(event_loop)
      event_loop.mark_workflow_admission(
        execution.workflow_instance_id,
        owner_token: execution.owner_token,
        state: :persisting_terminal
      )

      operation = Phronomy::WorkflowRunner::WorkflowTerminalPersistenceCommand.new(
        repository: execution.repository,
        workflow_instance_id: execution.workflow_instance_id.to_s.freeze,
        expected_revision: execution.expected_revision,
        snapshot: deep_immutable_copy(snapshot_for(context))
      )

      task = runtime.offload.submit(on_full: :raise) do
        revision = operation.repository.save(
          operation.workflow_instance_id,
          expected_revision: operation.expected_revision,
          snapshot: operation.snapshot
        )
        Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :success,
          revision: revision,
          error: nil
        )
      rescue Phronomy::Persistence::ConflictError,
        Phronomy::Persistence::NotFoundError,
        Phronomy::Persistence::SerializationError,
        Phronomy::Persistence::UnsupportedBackendError => error
        Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :known_failure,
          revision: nil,
          error: error
        )
      rescue => error
        reconcile_workflow_terminal_f1(operation, error)
      end

      task.on_complete do |result, operation_error|
        delivery = if operation_error
          Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
            outcome: :outcome_unknown,
            revision: nil,
            error: operation_error
          )
        else
          result
        end
        accepted = event_sink.post(:workflow_terminal_persistence_result, delivery)
        unless accepted
          Phronomy.configuration.logger&.warn(
            "[Phronomy] EventLoop rejected Workflow terminal persistence result " \
            "for #{execution.workflow_instance_id.inspect}"
          )
        end
      end
      terminal_type
    end

    def reconcile_workflow_terminal_f1(operation, original_error)
      record = operation.repository.load(operation.workflow_instance_id)
      case Phronomy::Recovery.compare_revisioned_snapshot(
        record: record,
        expected_pre_revision: operation.expected_revision,
        intended_snapshot: operation.snapshot
      )
      when :post_state
        revision = Phronomy::Recovery.fetch_value(record, :revision)
        Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :success,
          revision: revision,
          error: nil
        )
      when :pre_state
        # The uncertain save is now known not to have committed. Do not blindly
        # retry it here; surface a known failure through the ordinary terminal
        # barrier semantics.
        Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :known_failure,
          revision: nil,
          error: original_error
        )
      else
        conflict = Phronomy::Persistence::ConflictError.new(
          "Workflow terminal Persistence outcome conflicts with both expected " \
          "pre-state and intended post-state for #{operation.workflow_instance_id.inspect}"
        )
        Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :outcome_unknown,
          revision: nil,
          error: conflict
        )
      end
    rescue => reconciliation_error
      Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
        outcome: :outcome_unknown,
        revision: nil,
        error: reconciliation_error
      )
    end
  end
end

Phronomy::WorkflowRunner.prepend(Phronomy::WorkflowRecovery)
