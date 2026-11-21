# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent execution registration ownership" do
  let(:entered) { Queue.new }
  let(:release) { Queue.new }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "registration-ownership", version: 1
      model "offline-model"
    end
  end
  let(:owner) { agent_class.create(agent_id: "registered-owner") }
  let(:candidate) { agent_class.create(agent_id: "rejected-candidate") }
  let(:runtime) { Phronomy::Runtime.instance }
  let(:registry) { Phronomy::Agent::ExecutionRegistry.for(runtime.event_loop) }
  let(:execution_id) { "shared-execution-id" }

  before do
    started, gate = entered, release
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        started << true
        gate.pop(timeout: 10)
        Phronomy::LLMAdapter::Response.new(content: "owner-result", finish_reason: :stop)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def on_loop(&action)
    completion = Phronomy::TaskResult.deferred(name: "registration-test-barrier")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completion.complete(action.call)
    rescue => error
      completion.fail(error)
    end
    registry.post(Struct.new(:coordinator).new(handler), completion: completion)
    completion.wait_result(timeout: 3)
  end

  def start(agent, id = execution_id)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: id)
    agent.start_hosted(reservation: reservation, input: "input")
  end

  def live_owner
    on_loop do
      state = registry.agent_execution_state(execution_id)
      {state: state, phase: owner.__execution_environment.session_phase(state.fsm_session_id),
       waiters: registry.instance_variable_get(:@agent_completion_waiters).fetch(execution_id).dup,
       work: registry.agent_inflight_work_count(execution_id),
       admitted: registry.agent_execution_admitted?(owner.agent_id)}
    end
  end

  def hold_owner
    @owner_task = start(owner)
    @owner_notifications = Queue.new
    @owner_task.on_complete { |value, error| @owner_notifications << [value, error] }
    expect(entered.pop(timeout: 3)).to be(true)
    before = live_owner
    expect(before[:state].agent).to equal(owner)
    expect(before[:work]).to be_positive
    before
  end

  def finish_owner(before)
    expect(runtime.state).to eq(:running)
    expect(@owner_notifications).to be_empty
    expect(live_owner).to eq(before)
    release << true
    expect(@owner_task.wait_result(timeout: 5).fetch(:output)).to eq("owner-result")
    expect(owner.persistence.executions.load(execution_id).status).to eq(:completed)
    expect(on_loop { registry.agent_execution_state(execution_id) }).to be_nil
    expect(on_loop { registry.take_agent_completion_waiters(execution_id) }).to be_empty
  end

  after do
    release << true
    begin
      @owner_task&.wait_result(timeout: 5)
    rescue
      # A baseline failure must not leave the provider fixture blocked in teardown.
      nil
    end
  end

  it "rejects a duplicate ID without releasing or notifying the live owner" do
    before = hold_owner
    task = start(candidate)
    expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::Error, /already live/)
    expect(candidate.persistence.executions.load(execution_id).status).to eq(:failed)
    expect(on_loop { registry.agent_execution_admitted?(candidate.agent_id) }).to be(false)
    finish_owner(before)
    expect(candidate.unload_async.wait_result(timeout: 3)).to be(true)
  end

  [:build_agent_session, :register_session].each do |boundary|
    it "terminalizes #{boundary} failure without leaving its own state or waiters" do
      environment = candidate.__execution_environment
      allow(environment).to receive(boundary).and_raise(IOError, "session setup failed")
      task = start(candidate)
      expect { task.wait_result(timeout: 5) }.to raise_error(IOError, "session setup failed")
      expect(candidate.persistence.executions.load(execution_id).status).to eq(:failed)
      expect(runtime.state).to eq(:running)
      on_loop do
        expect(registry.agent_execution_state(execution_id)).to be_nil
        expect(registry.agent_execution_admitted?(candidate.agent_id)).to be(false)
        expect(registry.take_agent_completion_waiters(execution_id)).to be_empty
      end
      expect(candidate.unload_async.wait_result(timeout: 3)).to be(true)
    end
  end

  it "does not drain another owner's waiters when a correlated terminal commit fails" do
    before = hold_owner
    failure = IOError.new("correlated terminal unavailable")
    committer = candidate.send(:execution_coordinator).instance_variable_get(:@outcome_committer)
    allow(committer).to receive(:commit_outcome).and_raise(failure)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: candidate.agent_id,
      execution_id: execution_id, correlation: {"owner" => "candidate-coordination"})
    participant = Object.new
    participant.define_singleton_method(:admit) { |admission| admission.accept }
    task = candidate.start_reserved_async(reservation: reservation, input: "input",
      config: {phronomy_admission: participant})
    expect { task.wait_result(timeout: 5) }.to raise_error(failure)
    expect(candidate.persistence.executions.load(execution_id)).to be_active
    expect(on_loop { registry.agent_execution_admitted?(candidate.agent_id) }).to be(false)
    finish_owner(before)
  end

  [:commit, :submission].each do |boundary|
    it "keeps the live owner intact when duplicate-start terminal #{boundary} fails" do
      before = hold_owner
      failure = IOError.new("terminal #{boundary} unavailable")
      if boundary == :commit
        committer = candidate.send(:execution_coordinator).instance_variable_get(:@outcome_committer)
        allow(committer).to receive(:commit_outcome).and_raise(failure)
      else
        calls = 0
        allow(candidate.__execution_environment).to receive(:submit).and_wrap_original do |original, **options, &work|
          calls += 1
          raise failure if calls == 2
          original.call(**options, &work)
        end
      end
      task = start(candidate)
      expect { task.wait_result(timeout: 5) }.to raise_error(failure)
      expect(candidate.persistence.executions.load(execution_id)).to be_active
      expect(on_loop { registry.agent_execution_admitted?(candidate.agent_id) }).to be(true)
      finish_owner(before)
    end
  end
end
