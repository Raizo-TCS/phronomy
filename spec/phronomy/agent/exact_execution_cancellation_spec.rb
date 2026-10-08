# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ExactExecution do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:persistence) { stores.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "exact-cancellation", version: 1
    end
  end
  let(:agent) { agent_class.create(agent_id: "exact-owner", persistence: persistence) }
  let(:token) { Phronomy::Concurrency::CancellationToken.new.cancel! }
  let(:metadata) { {"current_input_ref" => persistence.contents.put_text("input")} }
  let(:execution) do
    record = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: "exact-run", kind: :external_message, channel: :llm, role: :user,
      content_ref: metadata.fetch("current_input_ref"),
      context_generation: agent.agent_root.transcript_generation, context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: record, execution_id: "exact-run", metadata: metadata)
      .with(status: :active, phase: :calling_llm)
  end

  def start(**options)
    described_class.start(agent: agent, execution_id: execution.execution_id, input: "input",
      config: {cancellation_token: token}, **options).wait_result(timeout: 5)
  end

  def cancellation_recorded?
    persistence.cancellation_requested?(agent_id: agent.agent_id, execution_id: execution.execution_id)
  end

  before { persistence.transaction { |tx| tx.executions.create_active(execution) } }

  it "records before recovery installation, independently of execution revision" do
    allow(Phronomy::Agent::RecoveryCoordinator).to receive(:new).with(agent) do
      expect(cancellation_recorded?).to be(true)
      expect(persistence.executions.load(execution.execution_id).execution_revision).to eq(execution.execution_revision)
      raise Phronomy::ExecutionRehydrationRequiredError, "test recovery boundary"
    end
    expect { start }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /test recovery boundary/)
  end

  it "does not install recovery or signal an owner if recording fails" do
    allow(persistence).to receive(:request_cancellation).and_raise(IOError, "cancellation write unavailable")
    expect(Phronomy::Agent::RecoveryCoordinator).not_to receive(:new)
    expect(agent.__execution_environment).not_to receive(:registry)
    expect { start }.to raise_error(IOError, /cancellation write unavailable/)
    expect(cancellation_recorded?).to be(false)
  end

  it "validates input before accepting cancellation" do
    expect { start(input: "wrong") }.to raise_error(Phronomy::Persistence::StateConflictError, /input mismatch/)
    expect(cancellation_recorded?).to be(false)
  end

  it "validates reservation correlation before accepting cancellation" do
    expect { start(config: {cancellation_token: token, phronomy_reservation: {"other" => true}}) }
      .to raise_error(Phronomy::Persistence::StateConflictError, /correlation mismatch/)
    expect(cancellation_recorded?).to be(false)
  end

  it "validates the Agent owner before accepting cancellation" do
    other = agent_class.create(agent_id: "other-owner", persistence: persistence)
    expect { start(agent: other) }.to raise_error(Phronomy::Persistence::StateConflictError, /another Agent/)
    expect(cancellation_recorded?).to be(false)
  end

  it "does not record an absent execution or start it with a cancelled token" do
    expect { start(execution_id: "absent", resume_only: true) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect { start(execution_id: "absent") }.to raise_error(Phronomy::CancellationError)
    expect(persistence.cancellation_requested?(agent_id: agent.agent_id, execution_id: "absent")).to be(false)
  end

  it "preserves an already completed result without recording a new cancellation" do
    completed = execution.with(status: :completed, phase: :completed, result_ref: persistence.contents.put_text("answer"))
    persistence.executions.save(execution.execution_id, expected_revision: execution.execution_revision, execution: completed)
    expect(start[:output]).to eq("answer")
    expect(cancellation_recorded?).to be(false)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(completed.to_h)
  end

  it "preserves completion that wins the race with cancellation recording" do
    completed = execution.with(status: :completed, phase: :completed, result_ref: persistence.contents.put_text("winner"))
    allow(persistence).to receive(:request_cancellation).and_wrap_original do |request, **args|
      persistence.executions.save(execution.execution_id, expected_revision: execution.execution_revision, execution: completed)
      request.call(**args)
    end
    expect(start[:output]).to eq("winner")
    expect(cancellation_recorded?).to be(false)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(completed.to_h)
  end

  context "participant-bound execution" do
    let(:metadata) { super().merge("execution_extension" => Phronomy::Agent::ExecutionExtensionState.new(binding_key: "test.binding", binding_version: 1).to_h) }

    it "requires the matching participant before accepting cancellation" do
      expect { start }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /participant binding/)
      expect(cancellation_recorded?).to be(false)
    end
  end

  it "persists a token cancelled between preparation and EventLoop delivery before signaling" do
    token = Phronomy::Concurrency::CancellationToken.new
    live_token = Phronomy::Concurrency::CancellationToken.new
    state = double(agent: agent, invocation: double(config: {cancellation_token: live_token}),
      execution: execution, fsm_session_id: nil)
    registry = double(agent_execution_owner: true, agent_execution_state: state)
    environment = agent.__execution_environment
    allow(environment).to receive(:existing_registry).and_return(registry)
    allow(environment).to receive(:registry).and_return(registry)
    posts = 0
    allow(registry).to receive(:post) do |command, completion:|
      posts += 1
      if posts == 1
        expect(cancellation_recorded?).to be(false)
        token.cancel!
      else
        expect(cancellation_recorded?).to be(true)
        expect(live_token).not_to be_cancelled
      end
      command.coordinator.deliver_on_event_loop(command)
      true
    end
    expect { start(config: {cancellation_token: token}) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(posts).to eq(2)
    expect(live_token).to be_cancelled
    expect(cancellation_recorded?).to be(true)
  end
end
