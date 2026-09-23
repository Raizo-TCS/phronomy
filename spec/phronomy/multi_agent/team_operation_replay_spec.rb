# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team operation result replay" do
  include_context "durable coordination runtime"

  it "returns a legacy saved result after restart without enqueueing or rewriting it" do
    team = team_class.create(team_id: "legacy-operation-result", persistence: store)
    LLMStub.activate(responses: team_responses)
    team.invoke("plan")
    run = team.executions.first
    key, operation = run.metadata.fetch("operations").find { |_id, entry| entry.fetch("operation") == "enqueue_task" }
    legacy_result = "TaskResult #1 enqueued: task-one"
    store.transaction do |tx|
      current = tx.team_executions.load(run.team_execution_id)
      operations = current.metadata.fetch("operations").merge(key => operation.merge("result" => legacy_result))
      tx.team_executions.save(current.team_execution_id, expected_revision: current.execution_revision,
        execution: current.with(metadata: current.metadata.merge("operations" => operations)))
    end

    restored = reboot(store.snapshot)
    loaded = team_class.load(team.team_id, persistence: restored)
    before = loaded.executions.first.to_h
    tool = loaded.send(:build_operation_tool, run.team_execution_id, :enqueue_task).new
    llm = LLMStub.activate(responses: ["must not run"])
    completion = tool.call_async(operation.fetch("arguments"), config: {phronomy_tool_invocation_id: key})

    expect(completion).to be_a(Phronomy::TaskResult)
    expect(completion.wait_result(timeout: 3)).to eq(legacy_result)
    expect(loaded.executions.first.to_h).to eq(before)
    expect(llm.calls).to be_empty

    expect do
      loaded.send(:apply_operation, run.team_execution_id, key, :enqueue_task, {description: "changed"})
    end.to raise_error(Phronomy::Storage::ConflictError, /identity mismatch/)
    expect(loaded.executions.first.to_h).to eq(before)
  end
end
