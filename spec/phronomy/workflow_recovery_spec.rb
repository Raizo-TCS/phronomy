# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::WorkflowRecovery do
  Repository = Struct.new(:record) do
    def load(_workflow_instance_id)
      record
    end
  end

  def operation(record:, expected_revision:, snapshot:)
    Phronomy::WorkflowRunner::WorkflowTerminalPersistenceCommand.new(
      repository: Repository.new(record),
      workflow_instance_id: "wf-1",
      expected_revision: expected_revision,
      snapshot: snapshot
    )
  end

  it "classifies F1 as committed when authoritative state equals intended post-state" do
    intended = {fields: {value: 2}, phase: "done"}
    op = operation(
      record: {revision: 3, snapshot: intended},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(
      :reconcile_workflow_terminal_f1,
      op,
      RuntimeError.new("response lost")
    )

    expect(result.outcome).to eq(:success)
    expect(result.revision).to eq(3)
  end

  it "classifies F1 as known failure when authoritative state remains at expected pre-state" do
    intended = {fields: {value: 2}, phase: "done"}
    error = RuntimeError.new("response lost")
    op = operation(
      record: {revision: 2, snapshot: {fields: {value: 1}, phase: "wait"}},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(:reconcile_workflow_terminal_f1, op, error)

    expect(result.outcome).to eq(:known_failure)
    expect(result.error).to equal(error)
  end

  it "keeps F1 unresolved when authoritative state matches neither pre nor intended post" do
    intended = {fields: {value: 2}, phase: "done"}
    op = operation(
      record: {revision: 3, snapshot: {fields: {value: 99}, phase: "done"}},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(
      :reconcile_workflow_terminal_f1,
      op,
      RuntimeError.new("response lost")
    )

    expect(result.outcome).to eq(:outcome_unknown)
    expect(result.error).to be_a(Phronomy::Persistence::ConflictError)
  end
end
