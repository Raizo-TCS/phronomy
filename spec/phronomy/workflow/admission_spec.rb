# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Workflow durable admission" do
  class WorkflowAdmissionContext
    include Phronomy::WorkflowContext

    field :value, type: :replace, default: 0
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  def eventually(timeout: 2)
    Timeout.timeout(timeout) do
      loop do
        value = yield
        return value if value
        sleep 0.005
      end
    end
  end

  def waiting_workflow(persistence: nil)
    Phronomy::Workflow.define(
      WorkflowAdmissionContext,
      persistence: persistence
    ) do
      initial :waiting
      state :waiting
      state :done
      transition from: :waiting, on: :finish, to: :done
      transition from: :done, to: :__finish__
    end
  end

  def finishing_workflow(persistence:)
    Phronomy::Workflow.define(
      WorkflowAdmissionContext,
      persistence: persistence
    ) do
      initial :done
      state :done, action: ->(context) { context.merge(value: context.value + 1) }
      transition from: :done, to: :__finish__
    end
  end

  it "separates Workflow identity, admission ownership, and FSMSession routing" do
    workflow = waiting_workflow
    task = workflow.invoke_async(
      {value: 1},
      config: {workflow_instance_id: "workflow-42", session_id: "rails-session-7"}
    )
    event_loop = Phronomy::Runtime.instance.event_loop

    first_fsm_session_id = eventually do
      event_loop.workflow_admission_fsm_session_id("workflow-42")
    end
    first_owner = event_loop.workflow_admission_owner("workflow-42")

    expect(first_owner).not_to be_nil
    expect(first_owner).not_to be_a(String)
    expect(first_fsm_session_id).to be_a(String)
    expect(first_fsm_session_id).not_to eq("workflow-42")
    expect(first_fsm_session_id).not_to eq("rails-session-7")
    expect(first_owner).not_to equal(first_fsm_session_id)

    expect(workflow.signal(workflow_instance_id: "workflow-42", event: :finish)).to be(true)
    expect(task.wait_result.workflow_instance_id).to eq("workflow-42")
    expect(event_loop.workflow_admission_owner("workflow-42")).to be_nil

    second_task = workflow.invoke_async(
      {value: 2},
      config: {workflow_instance_id: "workflow-42", session_id: "rails-session-7"}
    )
    second_fsm_session_id = eventually do
      event_loop.workflow_admission_fsm_session_id("workflow-42")
    end
    second_owner = event_loop.workflow_admission_owner("workflow-42")

    expect(second_owner).not_to equal(first_owner)
    expect(second_fsm_session_id).not_to eq(first_fsm_session_id)
    expect(workflow.signal(workflow_instance_id: "workflow-42", event: :finish)).to be(true)
    second_task.wait_result
  end

  it "acquires admission before durable Workflow load" do
    persistence = Phronomy::Persistence::InMemory.new
    repository = persistence.workflow_states
    load_entered = Queue.new
    allow_load = Queue.new
    load_calls = Queue.new

    blocking_repository = Object.new
    blocking_repository.define_singleton_method(:load) do |workflow_instance_id|
      load_calls << workflow_instance_id
      if workflow_instance_id == "shared" && load_entered.empty?
        load_entered << true
        allow_load.pop
      end
      repository.load(workflow_instance_id)
    end
    blocking_repository.define_singleton_method(:save) do |workflow_instance_id, expected_revision:, snapshot:|
      repository.save(
        workflow_instance_id,
        expected_revision: expected_revision,
        snapshot: snapshot
      )
    end
    blocking_repository.define_singleton_method(:delete) do |workflow_instance_id, expected_revision:|
      repository.delete(workflow_instance_id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(blocking_repository)

    workflow = waiting_workflow(persistence: persistence)
    first = workflow.invoke_async({}, config: {workflow_instance_id: "shared"})
    load_entered.pop

    event_loop = Phronomy::Runtime.instance.event_loop
    expect(event_loop.workflow_admission_state("shared")).to eq(:admitting)
    expect(event_loop.workflow_admission_fsm_session_id("shared")).to be_nil

    competitor = workflow.invoke_async({}, config: {workflow_instance_id: "shared"})
    expect { competitor.wait_result }
      .to raise_error(Phronomy::Error, /live execution segment/)

    # The rejected competitor never reaches Persistence.load.
    expect(load_calls.size).to eq(1)

    allow_load << true
    eventually { event_loop.workflow_admission_fsm_session_id("shared") }
    expect(workflow.signal(workflow_instance_id: "shared", event: :finish)).to be(true)
    first.wait_result
  end

  it "keeps the FSMSession nonterminal until terminal save succeeds" do
    persistence = Phronomy::Persistence::InMemory.new
    repository = persistence.workflow_states
    save_entered = Queue.new
    allow_save = Queue.new

    blocking_repository = Object.new
    blocking_repository.define_singleton_method(:load) do |workflow_instance_id|
      repository.load(workflow_instance_id)
    end
    blocking_repository.define_singleton_method(:save) do |workflow_instance_id, expected_revision:, snapshot:|
      save_entered << true
      allow_save.pop
      repository.save(
        workflow_instance_id,
        expected_revision: expected_revision,
        snapshot: snapshot
      )
    end
    blocking_repository.define_singleton_method(:delete) do |workflow_instance_id, expected_revision:|
      repository.delete(workflow_instance_id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(blocking_repository)

    workflow = finishing_workflow(persistence: persistence)
    task = workflow.invoke_async({value: 0}, config: {workflow_instance_id: "barrier"})
    save_entered.pop

    event_loop = Phronomy::Runtime.instance.event_loop
    fsm_session_id = event_loop.workflow_admission_fsm_session_id("barrier")
    expect(event_loop.workflow_admission_state("barrier")).to eq(:persisting_terminal)
    expect(event_loop.admitted_fsm_session?(fsm_session_id)).to be(true)
    expect(task.status).to eq(:pending)

    competitor = workflow.invoke_async({}, config: {workflow_instance_id: "barrier"})
    expect { competitor.wait_result }
      .to raise_error(Phronomy::Error, /live execution segment/)

    allow_save << true
    expect(task.wait_result.value).to eq(1)
    expect(event_loop.workflow_admission_owner("barrier")).to be_nil
  end

  it "does not publish a halted stream state before its durable save succeeds" do
    persistence = Phronomy::Persistence::InMemory.new
    repository = persistence.workflow_states
    save_entered = Queue.new
    allow_save = Queue.new
    observed = Queue.new

    blocking_repository = Object.new
    blocking_repository.define_singleton_method(:load) { |id| repository.load(id) }
    blocking_repository.define_singleton_method(:save) do |id, expected_revision:, snapshot:|
      save_entered << true
      allow_save.pop
      repository.save(id, expected_revision: expected_revision, snapshot: snapshot)
    end
    blocking_repository.define_singleton_method(:delete) do |id, expected_revision:|
      repository.delete(id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(blocking_repository)

    workflow = Phronomy::Workflow.define(
      WorkflowAdmissionContext,
      persistence: persistence
    ) do
      initial :awaiting
      wait_state :awaiting
    end

    thread = Thread.new do
      workflow.stream(
        {},
        config: {workflow_instance_id: "stream-barrier"}
      ) { |event| observed << event }
    end

    save_entered.pop
    expect(observed.empty?).to be(true)
    allow_save << true

    event = Timeout.timeout(2) { observed.pop }
    expect(event[:state]).to eq(:awaiting)
    expect(thread.value.halted?).to be(true)
  end

  it "treats a portable compare-and-swap failure as a known terminal failure" do
    persistence = Phronomy::Persistence::InMemory.new
    repository = persistence.workflow_states

    failing_repository = Object.new
    failing_repository.define_singleton_method(:load) { |id| repository.load(id) }
    failing_repository.define_singleton_method(:save) do |_id, expected_revision:, snapshot:|
      raise Phronomy::Persistence::ConflictError,
        "forced conflict revision=#{expected_revision.inspect} snapshot=#{!snapshot.nil?}"
    end
    failing_repository.define_singleton_method(:delete) do |id, expected_revision:|
      repository.delete(id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(failing_repository)

    workflow = finishing_workflow(persistence: persistence)
    task = workflow.invoke_async({}, config: {workflow_instance_id: "known-failure"})

    expect { task.wait_result }
      .to raise_error(Phronomy::Persistence::ConflictError, /forced conflict/)
    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("known-failure"))
      .to be_nil
  end

  it "fails closed when terminal save may have committed but its outcome is unknown" do
    persistence = Phronomy::Persistence::InMemory.new
    repository = persistence.workflow_states
    save_returned = Queue.new

    uncertain_repository = Object.new
    uncertain_repository.define_singleton_method(:load) { |id| repository.load(id) }
    uncertain_repository.define_singleton_method(:save) do |id, expected_revision:, snapshot:|
      revision = repository.save(
        id,
        expected_revision: expected_revision,
        snapshot: snapshot
      )
      save_returned << revision
      raise IOError, "connection lost after commit"
    end
    uncertain_repository.define_singleton_method(:delete) do |id, expected_revision:|
      repository.delete(id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(uncertain_repository)

    workflow = finishing_workflow(persistence: persistence)
    task = workflow.invoke_async({}, config: {workflow_instance_id: "uncertain"})
    expect(save_returned.pop).to eq(1)

    event_loop = Phronomy::Runtime.instance.event_loop
    eventually { event_loop.workflow_admission_state("uncertain") == :recovery_required }

    # Durable storage did advance, but this Runtime did not receive a known
    # success. The barrier therefore remains closed and the caller Task is not
    # falsely settled as success/failure.
    expect(repository.load("uncertain")[:revision]).to eq(1)
    expect(task.status).to eq(:pending)
    expect(event_loop.workflow_admission_fsm_session_id("uncertain")).to be_nil

    competitor = workflow.invoke_async({}, config: {workflow_instance_id: "uncertain"})
    expect { competitor.wait_result }
      .to raise_error(Phronomy::Error, /live execution segment/)
    expect(task.status).to eq(:pending)
  end
end
