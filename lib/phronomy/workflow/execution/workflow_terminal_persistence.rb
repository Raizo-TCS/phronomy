# frozen_string_literal: true

module Phronomy
  # Repository I/O and evidence classification for an immutable terminal save.
  # The caller owns scheduling, retained responsibility and owner-side release.
  # This component never restarts a Workflow or chooses a recovery Runtime.
  # @api private
  class WorkflowTerminalPersistence
    Command = Data.define(:repository, :workflow_instance_id, :expected_revision, :snapshot)
    Result = Data.define(:outcome, :revision, :error)

    def self.save(operation, on_error: nil)
      revision = operation.repository.save(
        operation.workflow_instance_id,
        expected_revision: operation.expected_revision,
        snapshot: operation.snapshot
      )
      Result.new(
        outcome: :success,
        revision: revision,
        error: nil
      )
    rescue Phronomy::Persistence::ConflictError,
      Phronomy::Persistence::NotFoundError,
      Phronomy::Persistence::SerializationError,
      Phronomy::Persistence::UnsupportedBackendError => error
      on_error&.call(error)
      Result.new(
        outcome: :known_failure,
        revision: nil,
        error: error
      )
    rescue => error
      on_error&.call(error)
      reconcile(operation, error)
    end

    def self.reconcile(operation, original_error)
      record = operation.repository.load(operation.workflow_instance_id)
      case Phronomy::Persistence::SnapshotComparison.compare_revisioned_snapshot(
        record: record,
        expected_pre_revision: operation.expected_revision,
        intended_snapshot: operation.snapshot,
        intended_post_revision: operation.expected_revision.nil? ? 1 : operation.expected_revision + 1
      )
      when :post_state
        revision = Phronomy::Persistence::SnapshotComparison.fetch_value(record, :revision)
        Result.new(
          outcome: :success,
          revision: revision,
          error: nil
        )
      when :pre_state
        # The uncertain save is now known not to have committed. Do not blindly
        # retry it here; surface a known failure through the ordinary terminal
        # barrier semantics.
        Result.new(
          outcome: :known_failure,
          revision: nil,
          error: original_error
        )
      else
        conflict = Phronomy::Persistence::StateConflictError.new(
          "Workflow terminal Persistence outcome conflicts with both expected " \
          "pre-state and intended post-state for #{operation.workflow_instance_id.inspect}"
        )
        Result.new(
          outcome: :outcome_unknown,
          revision: nil,
          error: conflict
        )
      end
    rescue => reconciliation_error
      Result.new(
        outcome: :outcome_unknown,
        revision: nil,
        error: reconciliation_error
      )
    end
  end
end
