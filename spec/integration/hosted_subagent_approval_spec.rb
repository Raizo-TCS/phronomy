# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"
require "timeout"

RSpec.describe "Hosted Orchestrator with a child awaiting approval", :integration do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:child_class) { IntegrationFactors.approval_resume_agent(IntegrationFactors.approval_tool) }
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

  it "releases both local owners, preserves their saved executions and restores the original child request" do
    recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    handle, request, child = start
    saved = saved_state(request.execution_id)

    wait = detach(handle, request)
    expect(wait.execution_revision).to eq(stores.agent.executions.load(request.execution_id).execution_revision)
    expect(wait.execution_id).to eq(request.execution_id)
    expect(wait.approval_request_id).to eq(request.id)
    expect(stores.agent.standalone_approval_wait(agent_id: child.agent_id, execution_id: request.execution_id)).to be_nil
    [parent, child].each do |original|
      expect(original.class.get(original.agent_id)).to be_nil
      expect { original.transcript }.to raise_error(Phronomy::AgentUnloadedError)
    end
    expect { child.approve(request.execution_id, approval_request_id: request.id) }.to raise_error(Phronomy::AgentUnloadedError)
    token.cancel!
    expect(saved_state(request.execution_id)).to eq(saved)

    loaded = parent_class.load(parent.agent_id, **options)
    recovering = loaded.resume_async(root_id)
    restored = Timeout.timeout(8) { events.pop }
    expect([restored.id, restored.execution_id]).to eq([request.id, request.execution_id])
    expect { recovering.wait_result(timeout: 8) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
    replacement = child_class.get(child.agent_id)
    expect(replacement.approve(restored.execution_id, approval_request_id: restored.id)).to include(output: "child completed")
    expect(loaded.resume_async(root_id).wait_result(timeout: 8)).to include(execution_id: root_id, output: "parent completed")
    expect(recorder.calls.size).to eq(4)
  end

  it "rejects a different root's actual child and a mismatched approval without releasing either root" do
    LLMStub.activate(responses: [dispatch, protected_call, dispatch, protected_call])
    first, request, child = start
    other_parent = parent_class.create(**options)
    second, other, other_child = start(other_parent, SecureRandom.uuid)
    expect { detach(first, other) }.to raise_error(Phronomy::AgentBusyError)
    expect { first.detach!(execution_id: request.execution_id, approval_request_id: other.id) }.to raise_error(Phronomy::AgentBusyError)
    [parent, child, other_parent, other_child].each { |agent| expect_live(agent) }
    expect(detach(first, request).approval_request_id).to eq(request.id)
    expect_live(other_parent)
    expect_live(other_child)
    expect(detach(second, other).approval_request_id).to eq(other.id)
  end

  it "requires a committed parent wait even if an unrelated failure also requests rehydration" do
    LLMStub.activate(responses: [dispatch, protected_call])
    allow_any_instance_of(Phronomy::MultiAgent::DurableSubagentCoordinator).to receive(:commit).and_wrap_original do |commit, change|
      raise Phronomy::ExecutionRehydrationRequiredError, "failed parent commit" if change.kind == :terminal
      commit.call(change)
    end
    handle, request, child = start
    expect { detach(handle, request) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /failed parent commit/)
    expect_live(parent)
    expect_live(child)
  end

  it "leaves both owners in place when an accepted operation holds either Agent" do
    LLMStub.activate(responses: [dispatch, protected_call])
    handle, request, child = start
    [parent, child].each do |busy|
      lease = busy.send(:__acquire_operation!)
      begin
        expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
        expect_live(parent)
        expect_live(child)
      ensure
        lease.release
      end
    end
    expect(detach(handle, request).approval_request_id).to eq(request.id)
  end

  def tool_batch(second_name, second_arguments)
    entries = [["dispatch_to_worker", {input: "first"}], [second_name, second_arguments]]
    calls = entries.map.with_index do |(name, arguments), index|
      {id: "slot-#{index}", type: "function", function: {name: name, arguments: arguments.to_json}}
    end
    {"id" => "dispatch-batch", "object" => "chat.completion", "model" => "stub-model",
     "choices" => [{"index" => 0, "message" => {"role" => "assistant", "tool_calls" => calls},
                    "finish_reason" => "tool_calls"}],
     "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}}
  end

  it "refuses to detach one child when the parent has reserved another slot" do
    LLMStub.activate(responses: [tool_batch("dispatch_to_worker", {input: "second"}), protected_call])
    handle, request, child = start
    extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
      binding_key: Phronomy::MultiAgent::DurableSubagentCoordinator::BINDING_KEY)
    slots = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children")
    expect(slots.map { |slot| slot.fetch("input") }).to contain_exactly("first", "second")
    expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
    expect_live(parent)
    expect_live(child)
    expect(stores.agent.observe_execution(agent_id: child.agent_id, execution_id: request.execution_id)).to be_active
  end

  it "refuses a parent batch containing a native child and an ordinary Tool" do
    LLMStub.activate(responses: [tool_batch("no_approval_tool", {value: "second"}), protected_call])
    handle, request, child = start
    expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
    expect_live(parent)
    expect_live(child)
  end

  [:parent, :child].each do |cancelled|
    it "refuses transfer after a durable cancellation request for the #{cancelled}" do
      LLMStub.activate(responses: [dispatch, protected_call])
      handle, request, child = start
      target, id = (cancelled == :parent) ? [parent, root_id] : [child, request.execution_id]
      stores.agent.request_cancellation(agent_id: target.agent_id, execution_id: id)
      expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
      expect_live(parent)
      expect_live(child)
    end
  end
end
