# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Team-owned scheduling facts" do
  include_context "durable coordination runtime"

  it "balances by retained assignment count and resumes without consulting Agent journal positions" do
    team_class.pool(size: 2, agent: worker)
    team = team_class.create(team_id: "balanced", persistence: store.team)
    calls = [["enqueue_task", {description: "one"}], ["enqueue_task", {description: "two"}],
      ["enqueue_task", {description: "three"}], ["finalize", {}]].each_with_index.map do |(name, args), i|
      {"id" => "batch-#{i}", "type" => "function", "function" => {"name" => name, "arguments" => JSON.generate(args)}}
    end
    batch = {"id" => "balance-batch", "object" => "chat.completion", "model" => "stub-model",
             "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil, "tool_calls" => calls}, "finish_reason" => "tool_calls"}]}
    LLMStub.activate(responses: [batch, "queued", "one", "two", "three"])
    result = team.invoke("plan")
    run = team.executions.first
    expect(run.assignments.map { |entry| entry.fetch("worker") }).to eq([0, 1, 0])
    expect(run.workers).to all(satisfy { |entry| !entry.key?("transcript_size") })
    restored = reboot(store.snapshot)
    loaded = team_class.load(team.team_id, persistence: restored.team)
    llm = LLMStub.activate(responses: ["must not replay"])
    expect(loaded.resume(run.team_execution_id)).to eq(result)
    expect(loaded.executions.first.assignments).to eq(run.assignments)
    expect(llm.calls).to be_empty
  end
end
