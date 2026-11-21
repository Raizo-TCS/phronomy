# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "support/durable_coordination"

RSpec.describe "Coordinated Agents calling private Agent Tools" do
  include_context "durable coordination runtime"

  let(:private_children) { [] }
  let(:approvals) { Queue.new }
  let(:private_class) do
    children, events = private_children, approvals
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "coordination-private-tool-child", version: 1
      model "gpt-4o-mini"
      provider :openai
      define_method(:initialize) do |**options|
        listener = ->(event) { events << event.payload.fetch(:request) if event.type == :approval_required }
        super(**options.merge(on_event: listener))
        children << self
      end
    end
  end
  let(:private_tool) { Phronomy::Tools::Agent.from_agent(private_class, tool_name: "private_worker") }

  before do
    Phronomy.configure { |config| config.offload_pool_size = 1 }
    worker.tools private_tool => nil
  end

  def private_call
    LLMStub.tool_call_response("private_worker", {input: "detail"})
  end

  def expect_private_completion(parent_execution_ids)
    expect(private_children.size).to eq(1)
    child = private_children.first
    run = child.persistence.runs(child.agent_id).fetch(0)
    expect(run.status).to eq(:completed)
    expect(parent_execution_ids).not_to include(run.execution_id)
    expect(run.metadata).not_to have_key("reservation")
    expect(run.metadata).not_to have_key("execution_extension")
    expect(Phronomy::Agent::Base.get(child.agent_id)).to be_nil
    expect(Phronomy::Runtime.instance.state).to eq(:running)
  end

  it "preserves Team assignment identity and result while releasing its private descendant" do
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses.take(3) + [private_call, "private-result", "worker-result"])

    output = Timeout.timeout(8) { team.invoke("plan") }

    expect(output.first.fetch("result")).to eq("worker-result")
    run = team.executions.fetch(0)
    assignment_id = run.assignments.fetch(0).fetch("execution_id")
    expect(store.agent.result(assignment_id)).to include(status: :completed, result: "worker-result")
    expect(team.result(run.team_execution_id)).to include(status: "completed")
    expect_private_completion([assignment_id, run.coordinator.fetch("execution_id")])
    expect(team.resume(run.team_execution_id)).to eq(output)
    expect(llm.calls.size).to eq(6)
  end

  it "preserves durable subagent correlation without attaching it to the private grandchild" do
    parent = parent_class.create(persistence: store.agent, coordination_store: store.multi_agent)
    llm = LLMStub.activate(responses: [
      LLMStub.tool_call_response("dispatch_to_worker", {input: "job"}),
      private_call, "private-result", "worker-result", "parent-result"
    ])

    result = Timeout.timeout(8) { parent.invoke("plan") }

    expect(result).to include(output: "parent-result")
    run = store.agent.executions.load(result.fetch(:execution_id))
    state_ref = run.metadata.fetch("execution_extension").fetch("state_ref")
    assignment = store.multi_agent.contents.fetch_json(state_ref).fetch("children").fetch(0)
    child_id = assignment.fetch("execution_id")
    expect(store.agent.result(child_id)).to include(status: :completed, result: "worker-result")
    expect(store.agent.executions.load(child_id).metadata.fetch("reservation")).to include("kind" => "subagent")
    expect_private_completion([run.execution_id, child_id])
    expect(store.agent.result(run.execution_id)).to include(status: :completed, result: "parent-result")
    expect(llm.calls.size).to eq(5)
  end

  it "preserves the Handoff target as turn owner after its private Agent Tool completes" do
    source_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "nested-handoff-source", version: 1
      model "gpt-4o-mini"
      provider :openai
    end
    source = source_class.create(persistence: store.agent)
    target = worker.create(persistence: store.agent)
    edge = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    handoff_name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(edge).tool_name
    runner = Phronomy::MultiAgent::HandoffRunner.new(main_agent: source, persistence: store.multi_agent, handoffs: [edge])
    llm = LLMStub.activate(responses: [
      LLMStub.tool_call_response(handoff_name, {responsibility: "Handle the delegated case"}),
      private_call, "private-result", "target-result", "followup-result"
    ])

    result = Timeout.timeout(8) { runner.invoke("plan") }

    expect(result).to include(agent: target, output: "target-result")
    source_run = store.agent.runs(source.agent_id).fetch(0)
    target_run = store.agent.executions.load(result.fetch(:execution_id))
    expect(source_run.status).to eq(:handed_off)
    expect(target_run.status).to eq(:completed)
    expect(runner.result(source_run.execution_id)).to include(agent_id: target.agent_id, status: :completed)
    expect_private_completion([source_run.execution_id, target_run.execution_id])
    expect(Timeout.timeout(8) { runner.invoke("followup") }).to include(agent: target, output: "followup-result")
    expect(llm.calls.size).to eq(5)
  end

  it "keeps Team and private child active until the private child's approval is answered" do
    effects = []
    protected_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "approved_detail"
      description "Read detail only after approval"
      requires_approval true
      define_method(:execute) do
        effects << "read"
        "approved-detail"
      end
    end
    private_class.tools protected_tool => nil
    token = Phronomy::Concurrency::CancellationToken.new
    team = team_class.create(persistence: store.multi_agent)
    llm = LLMStub.activate(responses: team_responses.take(3) + [
      private_call, LLMStub.tool_call_response("approved_detail", {}), "private-result", "worker-result"
    ])
    thread = Thread.new { team.invoke("plan", config: {cancellation_token: token}) }
    thread.report_on_exception = false
    request = Timeout.timeout(5) { approvals.pop }
    child = private_children.fetch(0)
    run = team.executions.fetch(0)
    assignment_id = run.assignments.fetch(0).fetch("execution_id")

    expect(thread).to be_alive
    expect(run.status).to eq("active")
    expect(request.execution_id).not_to eq(assignment_id)
    expect(Phronomy::Agent::Base.get(child.agent_id)).to equal(child)
    expect(effects).to be_empty
    child.approve_async(request.execution_id, approval_request_id: request.id, approved: true).wait_result(timeout: 5)
    expect(thread.join(5)).not_to be_nil
    expect(thread.value.first.fetch("result")).to eq("worker-result")
    expect(team.result(run.team_execution_id)).to include(status: "completed")
    expect_private_completion([assignment_id, run.coordinator.fetch("execution_id")])
    expect(effects).to eq(["read"])
    expect(llm.calls.size).to eq(7)
  ensure
    token&.cancel!
    thread&.join(2)
  end
end
