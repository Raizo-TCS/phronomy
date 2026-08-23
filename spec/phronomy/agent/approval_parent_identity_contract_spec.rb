# frozen_string_literal: true

require "spec_helper"
require "time"

RSpec.describe "CG-03a Agent execution parent identity" do
  def approval_item
    Phronomy::Agent::ToolApprovalRequest::Item.new(
      tool_invocation_id: "tool-invocation-1",
      tool_call_id: "provider-call-1",
      tool_name: "lookup",
      arguments: {query: "example"},
      facts: {},
      reason: "approval required",
      origin: :local,
      metadata: {}
    )
  end

  it "uses execution_id on the public ToolApprovalRequest contract" do
    request = Phronomy::Agent::ToolApprovalRequest.new(
      execution_id: "execution-1",
      items: [approval_item],
      id: "approval-1",
      created_at: Time.utc(2026, 8, 23)
    )

    expect(request.execution_id).to eq("execution-1")
    expect(request).not_to respond_to(:agent_invocation_id)
    expect(request.to_h).to include(execution_id: "execution-1")
    expect(request.to_h).not_to have_key(:agent_invocation_id)
  end

  it "uses execution_id on approval policy input without a compatibility alias" do
    request = Phronomy::Agent::ApprovalEvaluationRequest.new(
      agent: Object.new,
      execution_id: "execution-1",
      tool: Object.new,
      tool_name: "lookup",
      tool_schema: {},
      tool_invocation_id: "tool-invocation-1",
      tool_call_id: "provider-call-1",
      arguments: {query: "example"}
    )

    expect(request.execution_id).to eq("execution-1")
    expect(request).not_to respond_to(:agent_invocation_id)

    updated = request.with(facts: {checked: true})
    expect(updated.execution_id).to eq("execution-1")
  end

  it "keeps AgentInvocation as a live execution context without its own ID" do
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: Object.new,
      input: "hello",
      config: {},
      execution_id: "execution-1"
    )

    expect(invocation.execution_id).to eq("execution-1")
    expect(invocation).not_to respond_to(:id, :session_id, :agent_invocation_id)
  end

  it "gives ToolInvocation an execution parent without storing Runtime routing" do
    invocation = Phronomy::Agent::ToolInvocation.new(
      execution_id: "execution-1",
      agent: Object.new,
      tool: nil,
      tool_call: Struct.new(:id, :name, :arguments).new(
        "provider-call-1", "missing", {}
      ),
      config: {}
    )

    expect(invocation.execution_id).to eq("execution-1")
    expect(invocation.id).not_to eq(invocation.execution_id)
    expect(invocation).not_to respond_to(
      :parent_agent_invocation_id, :session_id, :agent_invocation_id
    )
  end

  it "rejects legacy agent_invocation_id through public Agent config" do
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "cg03a-config-rejection", version: 1
    end
    agent = agent_class.new

    [:agent_invocation_id, "agent_invocation_id"].each do |key|
      expect {
        agent.invoke_async("hello", config: {key => "legacy-route"})
      }.to raise_error(ArgumentError, /agent_invocation_id.*removed/)
    end
  end

  it "normalizes legacy embedded durable approval parent from the enclosing execution" do
    legacy = {
      "execution_id" => "execution-1",
      "agent_id" => "agent-1",
      "execution_revision" => 3,
      "status" => "suspended",
      "phase" => "approval",
      "base_agent_revision" => 2,
      "base_context_revision" => 1,
      "base_journal_position" => 4,
      "working_records" => [],
      "llm_calls" => [],
      "approval_request" => {
        "id" => "approval-1",
        "agent_invocation_id" => "legacy-runtime-route",
        "items" => [],
        "created_at" => "2026-08-23T00:00:00Z"
      },
      "result_ref" => nil,
      "error_ref" => nil,
      "created_at" => "2026-08-23T00:00:00.000000Z",
      "updated_at" => "2026-08-23T00:00:01.000000Z",
      "terminal_reason" => nil,
      "metadata" => {}
    }

    restored = Phronomy::Agent::AgentExecution.from_h(legacy)
    approval = restored.approval_request

    expect(approval["execution_id"]).to eq("execution-1")
    expect(approval).not_to have_key("agent_invocation_id")
    expect(restored.to_h.fetch("approval_request"))
      .not_to have_key("agent_invocation_id")
  end

  it "represents the public approval execution parent in RBS" do
    root = File.expand_path("../../..", __dir__)
    rbs = File.read(File.join(root, "sig/phronomy/agent.rbs"))

    tool_section = rbs.split("class ToolApprovalRequest", 2).fetch(1)
      .split("class ApprovalEvaluationRequest", 2).fetch(0)
    evaluation_section = rbs.split("class ApprovalEvaluationRequest", 2).fetch(1)
      .split("class Base", 2).fetch(0)

    expect(tool_section).to include("attr_reader execution_id: String")
    expect(tool_section).not_to include("agent_invocation_id")
    expect(evaluation_section).to include("attr_reader execution_id: String")
    expect(evaluation_section).not_to include("agent_invocation_id")
  end
end
