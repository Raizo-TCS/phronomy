# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"
require "timeout"

RSpec.describe "Standalone hosted approval", :integration do
  let(:klass) { IntegrationFactors.approval_resume_agent(IntegrationFactors.approval_tool(result_value: "applied")) }
  let(:events) { Queue.new }
  let(:agent) { klass.new(on_event: ->(event) { events << event.payload.fetch(:request) if event.type == :approval_required }) }
  let(:reservation) { Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: SecureRandom.uuid) }

  after { LLMStub.deactivate }

  let(:token) { Phronomy::Concurrency::CancellationToken.new }

  def start
    LLMStub.activate(responses: [LLMStub.tool_call_response("approval_required_tool", {query: "check"}), "approved"])
    handle = agent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
    [handle, Timeout.timeout(8) { events.pop }]
  end

  it "releases just the hosted incarnation and resumes the same execution" do
    other = klass.new
    handle, request = start
    expect(request.execution_id).to eq(reservation.execution_id)
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect { handle.detach!(approval_request_id: "wrong") }.to raise_error(Phronomy::AgentBusyError)
    expect { agent.persistence.standalone_approval_wait(agent_id: other.agent_id, execution_id: request.execution_id) }
      .to raise_error(Phronomy::Persistence::StateConflictError)
    wait = handle.detach!(approval_request_id: request.id)
    expect(handle.wait_result(timeout: 2)).to eq(wait)
    expect(wait.approval_request_id).to eq(request.id)
    expect(agent.persistence.standalone_approval_wait(agent_id: agent.agent_id, execution_id: request.execution_id)).to eq(wait)
    expect { agent.invoke("old owner") }.to raise_error(Phronomy::AgentUnloadedError)
    loaded = klass.load(agent.agent_id, persistence: agent.persistence, on_event: ->(event) {
      events << event.payload.fetch(:request) if event.type == :approval_required
    })
    expect(Timeout.timeout(8) { events.pop }.id).to eq(request.id)
    expect { handle.detach!(approval_request_id: request.id) }.to raise_error(Phronomy::AgentBusyError)
    token.cancel!
    approved = loaded.approve(request.execution_id, approval_request_id: request.id)
    expect(approved).to include(execution_id: request.execution_id, output: "approved")
    expect(agent.persistence.standalone_approval_wait(agent_id: agent.agent_id, execution_id: request.execution_id)).to be_nil
    expect(other.unload!).to be(true)
  end

  it "does not detach while another accepted operation owns a lease" do
    handle, request = start
    lease = agent.send(:__acquire_operation!)
    begin
      expect { handle.detach!(approval_request_id: request.id) }.to raise_error(Phronomy::AgentBusyError)
    ensure
      lease.release
    end
    expect(handle.detach!(approval_request_id: request.id).execution_id).to eq(reservation.execution_id)
  end

  it "leaves a durable cancellation request authoritative" do
    handle, request = start
    agent.persistence.request_cancellation(agent_id: agent.agent_id, execution_id: request.execution_id)
    expect { handle.detach!(approval_request_id: request.id) }.to raise_error(Phronomy::AgentBusyError)
    expect(agent.persistence.standalone_approval_wait(agent_id: agent.agent_id, execution_id: request.execution_id)).to be_nil
  end

  it "keeps the owner and its wait available when the EventLoop rejects detach" do
    handle, request = start
    registry = agent.__execution_environment.registry
    RSpec::Mocks.with_temporary_scope do
      allow(registry).to receive(:post).and_call_original
      allow(registry).to receive(:post)
        .with(anything, hash_including(completion: kind_of(Phronomy::TaskResult))).and_return(false)
      expect { handle.detach!(approval_request_id: request.id) }
        .to raise_error(Phronomy::RuntimeShutdownError, "EventLoop rejected hosted detach")
    end
    wait = handle.detach!(approval_request_id: request.id)
    expect(wait.execution_id).to eq(request.execution_id)
    expect(handle.wait_result(timeout: 2)).to eq(wait)
  end

  it "can finish without a wait and rejects the reuse of a spent reservation" do
    LLMStub.activate(responses: ["done"])
    handle = agent.start_hosted(reservation: reservation, input: "run")
    settled = Queue.new
    expect(handle.on_complete { |value, error| settled << [value, error] }).to equal(handle)
    result = handle.wait_result(timeout: 8)
    expect(result).to include(output: "done", execution_id: reservation.execution_id)
    expect(Timeout.timeout(8) { settled.pop }).to eq([result, nil])
    expect { agent.start_hosted(reservation: reservation, input: "again") }.to raise_error(Phronomy::Persistence::StateConflictError)
  end

  it "declines coordinated reservations and absent waits" do
    reservation_with_parent = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id,
      execution_id: reservation.execution_id, correlation: {"parent" => "workflow"})
    expect { agent.start_hosted(reservation: reservation_with_parent, input: "run") }.to raise_error(ArgumentError)
    expect(agent.persistence.standalone_approval_wait(agent_id: agent.agent_id, execution_id: reservation.execution_id)).to be_nil
  end
end
