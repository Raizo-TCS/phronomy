# frozen_string_literal: true

require "spec_helper"
require_relative "../multi_agent/support/durable_coordination"

RSpec.describe "Structured output saved continuation (F4; no replay of confirmed Tool effects)" do
  include_context "durable coordination runtime"
  let(:schema) { {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false} }

  it "pins the schema through approval, reconstruction and the final model turn" do
    calls = 0
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "protected_operation"
      description "Count approved execution"
      requires_approval true
      define_method(:execute) {
        calls += 1
        "done"
      }
    end
    worker.tools tool => nil
    approvals = Queue.new
    listener = ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required }
    original = worker.create(agent_id: "structured-approval", persistence: store.agent, on_event: listener)
    first = LLMStub.activate(responses: [LLMStub.tool_call_response("protected_operation", {})])
    original.invoke_async("input", output_schema: schema)
    request = Timeout.timeout(3) { approvals.pop }
    pinned = store.agent.executions.load(request.execution_id).metadata.fetch("output_contract")
    schema[:properties][:answer][:type] = "number"
    expect(calls).to eq(0)
    recovered = reboot(store.snapshot)
    llm = LLMStub.activate(responses: ['{"answer":"approved"}'])
    loaded = worker.load(original.agent_id, persistence: recovered.agent, on_event: listener)
    restored = Timeout.timeout(3) { approvals.pop }
    result = loaded.approve(request.execution_id, approval_request_id: restored.id, approved: true)
    expect(result[:output]).to eq("answer" => "approved")
    expect(calls).to eq(1)
    expect(llm.calls.first.dig("response_format", "json_schema", "schema", "properties", "answer", "type")).to eq("string")
    expect(recovered.agent.executions.load(request.execution_id).metadata.fetch("output_contract")).to eq(pinned)
    expect(first.calls.length).to eq(1)
    expect(llm.calls.length).to eq(1)
  end

  [:stop, :length].each do |reason|
    it "restores saved #{reason} Provider facts before final output validation, without another request" do
      agent = worker.create(agent_id: "structured-resolution", persistence: store.agent)
      before_provider = nil
      store.after_commit = proc do |current|
        run = current.agent.runs(agent.agent_id).first
        before_provider ||= current.snapshot if run&.phase == :calling_llm
      end
      LLMStub.activate(responses: ['{"answer":"initial"}'])
      agent.invoke("input", output_schema: schema)
      backend = reboot(before_provider)
      unresolved = Queue.new
      loaded = worker.load(agent.agent_id, persistence: backend.agent,
        on_event: ->(event) { unresolved << event.payload if event.type == :recovery_resolution_required })
      event = Timeout.timeout(3) { unresolved.pop }
      id = event.fetch(:execution_id)
      saved_response = nil
      backend.after_commit = proc do |current|
        run = current.agent.executions.load(id)
        saved_response ||= current.snapshot if run.phase == :recovery_provider_completed
      end
      llm = LLMStub.activate(responses: ["must not replay"])
      response = Phronomy::LLMAdapter::Response.new(content: '{"answer":"resolved"}', finish_reason: reason)
      task = loaded.resolve_async(id, expected_execution_revision: event.fetch(:execution_revision),
        subject: event.fetch(:subject), outcome: :succeeded, result: response.to_h)
      if reason == :stop
        expect(task.wait_result(timeout: 3)[:output]).to eq("answer" => "resolved")
      else
        expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::Agent::OutputError) { |e| expect(e.reason).to eq("length") }
      end
      expect(llm.calls).to be_empty
      backend = reboot(saved_response)
      terminal = Queue.new
      llm = LLMStub.activate(responses: ["must not replay"])
      worker.load(agent.agent_id, persistence: backend.agent,
        on_event: ->(e) { terminal << e if %i[done error].include?(e.type) })
      outcome = Timeout.timeout(3) { terminal.pop }
      expect(outcome.type).to eq((reason == :stop) ? :done : :error)
      expect(llm.calls).to be_empty
      expect(backend.agent.executions.load(id).status).to eq((reason == :stop) ? :completed : :failed)
    end
  end
  it "does not repeat a completed Tool to repair invalid final output" do
    calls = 0
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "once_only"
      description "One confirmed effect"
      define_method(:execute) {
        calls += 1
        "done"
      }
    end
    worker.tools tool => nil
    agent = worker.create(persistence: store.agent)
    llm = LLMStub.activate(responses: [LLMStub.tool_call_response("once_only", {}), "broken output"])
    execution_id = nil
    expect { agent.invoke("input", output_schema: schema) }.to raise_error(Phronomy::Agent::OutputError) { |error| execution_id = error.execution_id }
    expect(calls).to eq(1)
    expect(llm.calls.length).to eq(2)
    backend = reboot(store.snapshot)
    loaded = worker.load(agent.agent_id, persistence: backend.agent)
    expect { loaded.resume(execution_id) }.to raise_error(Phronomy::Agent::OutputError)
    expect(calls).to eq(1)
    expect(llm.calls.length).to eq(2)
  end
end
