# frozen_string_literal: true

require_relative "factors"
require_relative "llm_stub"
require "timeout"

RSpec.shared_context "a native child requiring approval" do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:approval_tool) { IntegrationFactors.approval_tool }
  let(:child_class) { IntegrationFactors.approval_resume_agent(approval_tool) }
  let(:parent_class) do
    worker = child_class
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "hosted-approval-parent", version: 1
      model IntegrationFactors::LM_MODEL_30
      provider :openai
      tools IntegrationFactors::NoApprovalTool => nil
      subagent :worker, worker
    end
  end
  let(:events) { Queue.new }
  let(:options) do
    {persistence: stores.agent, coordination_store: stores.multi_agent,
     on_event: ->(event) { events << event.payload.fetch(:request) if event.type == :approval_required }}
  end
  let(:parent) { parent_class.create(**options) }
  let(:root_id) { SecureRandom.uuid }
  let(:token) { Phronomy::Concurrency::CancellationToken.new }
  let(:dispatch) { LLMStub.tool_call_response("dispatch_to_worker", {input: "child request"}) }
  let(:protected_call) { LLMStub.tool_call_response("approval_required_tool", {query: "check"}) }

  after { LLMStub.deactivate }

  def start(agent = parent, id = root_id)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: id)
    handle = agent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
    request = Timeout.timeout(8) { events.pop }
    expect { handle.wait_result(timeout: 8) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    child = child_class.get(stores.agent.execution_identity(request.execution_id).agent_id)
    [handle, request, child]
  end

  def detach(handle, request)
    handle.detach!(execution_id: request.execution_id, approval_request_id: request.id)
  end

  def saved_state(child_id)
    [root_id, child_id].map { |id| stores.agent.executions.load(id).to_h }
  end

  def expect_live(agent)
    expect(agent.class.get(agent.agent_id)).to equal(agent)
  end
end
