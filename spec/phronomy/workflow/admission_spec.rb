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

    # Post an event to the FSMSession while it is in persisting_terminal state.
    # The FSMSession must discard it without changing lifecycle state.
    stray_event = Phronomy::Event.new(type: :some_event, target_id: fsm_session_id, payload: nil)
    event_loop.post_to_session(stray_event)
    sleep 0.02  # let EventLoop process the discarded event
    expect(event_loop.workflow_admission_state("barrier")).to eq(:persisting_terminal)

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

  it "reconciles terminal save response loss when authoritative state is the intended post-state" do
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

    result = task.wait_result
    expect(result.value).to eq(1)
    expect(repository.load("uncertain")[:revision]).to eq(1)
    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("uncertain"))
      .to be_nil
  end

  # ---------------------------------------------------------------------------
  # Halting workflow helper: halts at wait_state for synchronous invoke tests.
  # ---------------------------------------------------------------------------
  def halting_workflow(persistence: nil)
    Phronomy::Workflow.define(
      WorkflowAdmissionContext,
      persistence: persistence
    ) do
      initial :running
      state :running, action: ->(ctx) { ctx.merge(value: ctx.value + 1) }
      wait_state :waiting
      state :done
      transition from: :running, to: :waiting
      transition from: :waiting, on: :finish, to: :done
      transition from: :done, to: :__finish__
    end
  end

  it "raises ArgumentError when send_event state has nil workflow_instance_id" do
    workflow = halting_workflow
    # A stub state that looks halted but has no durable identity.
    stub_state = Struct.new(:phase, :workflow_instance_id).new(:waiting, nil)
    expect { workflow.send_event(state: stub_state, event: :finish) }
      .to raise_error(ArgumentError, /workflow_instance_id/)
  end

  it "raises ConflictError when the durable snapshot has diverged since halt" do
    persistence = Phronomy::Persistence::InMemory.new
    repo = persistence.workflow_states
    workflow = halting_workflow(persistence: persistence)

    halted = workflow.invoke({value: 0}, config: {workflow_instance_id: "diverged"})
    expect(halted.halted?).to be(true)

    # Simulate an external actor advancing the durable state (no phase key
    # ensures the nil-phase branch of normalize_snapshot is also exercised).
    repo.save("diverged", expected_revision: 1, snapshot: {fields: {value: 99}})

    expect { workflow.send_event(state: halted, event: :finish) }
      .to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "propagates a repository load error during durable Workflow start" do
    persistence = Phronomy::Persistence::InMemory.new
    fail_repo = Object.new
    fail_repo.define_singleton_method(:load) { |_id| raise IOError, "load exploded on start" }
    fail_repo.define_singleton_method(:save) do |id, expected_revision:, snapshot:|
      persistence.workflow_states.save(id, expected_revision: expected_revision, snapshot: snapshot)
    end
    fail_repo.define_singleton_method(:delete) do |id, expected_revision:|
      persistence.workflow_states.delete(id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(fail_repo)

    workflow = finishing_workflow(persistence: persistence)
    task = workflow.invoke_async({value: 0}, config: {workflow_instance_id: "start-load-err"})
    expect { task.wait_result }.to raise_error(IOError, /load exploded on start/)
    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("start-load-err"))
      .to be_nil
  end

  it "propagates a repository load error during durable Workflow resume" do
    persistence = Phronomy::Persistence::InMemory.new
    real_repo = persistence.workflow_states
    load_count = 0
    flaky_repo = Object.new
    flaky_repo.define_singleton_method(:load) do |id|
      load_count += 1
      raise IOError, "load exploded on resume" if load_count > 1
      real_repo.load(id)
    end
    flaky_repo.define_singleton_method(:save) do |id, expected_revision:, snapshot:|
      real_repo.save(id, expected_revision: expected_revision, snapshot: snapshot)
    end
    flaky_repo.define_singleton_method(:delete) do |id, expected_revision:|
      real_repo.delete(id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(flaky_repo)

    workflow = halting_workflow(persistence: persistence)
    halted = workflow.invoke({value: 0}, config: {workflow_instance_id: "resume-load-err"})
    expect(halted.halted?).to be(true)

    expect { workflow.send_event(state: halted, event: :finish) }
      .to raise_error(IOError, /load exploded on resume/)
    expect(Phronomy::Runtime.instance.event_loop.workflow_admission_owner("resume-load-err"))
      .to be_nil
  end

  it "returns false from signal when the Workflow admission is no longer active" do
    workflow = waiting_workflow
    event_loop = Phronomy::Runtime.instance.event_loop
    task = workflow.invoke_async({value: 0}, config: {workflow_instance_id: "signal-gone"})

    # Wait until the FSMSession is bound (executing state) before signalling.
    eventually { event_loop.workflow_admission_fsm_session_id("signal-gone") }
    expect(workflow.signal(workflow_instance_id: "signal-gone", event: :finish)).to be(true)
    task.wait_result

    # Admission is released after completion; a late signal must return false.
    expect(workflow.signal(workflow_instance_id: "signal-gone", event: :finish)).to be(false)
  end

  it "handles a durable repository that returns string-keyed snapshot records on resume" do
    persistence = Phronomy::Persistence::InMemory.new
    real_repo = persistence.workflow_states
    # Wrap the repository so that returned records use string keys, exercising
    # record_value's string-key fallback and deep_immutable_copy's String-key branch.
    string_key_repo = Object.new
    string_key_repo.define_singleton_method(:load) do |id|
      record = real_repo.load(id)
      next nil unless record
      snap = record[:snapshot]
      str_snap = snap ? {
        "fields" => (snap[:fields] || {}).transform_keys(&:to_s),
        "phase" => snap[:phase]
      } : nil
      {"snapshot" => str_snap, "revision" => record[:revision]}
    end
    string_key_repo.define_singleton_method(:save) do |id, expected_revision:, snapshot:|
      real_repo.save(id, expected_revision: expected_revision, snapshot: snapshot)
    end
    string_key_repo.define_singleton_method(:delete) do |id, expected_revision:|
      real_repo.delete(id, expected_revision: expected_revision)
    end
    allow(persistence).to receive(:workflow_states).and_return(string_key_repo)

    workflow = halting_workflow(persistence: persistence)
    halted = workflow.invoke({value: 5}, config: {workflow_instance_id: "str-keys"})
    expect(halted.halted?).to be(true)

    result = workflow.send_event(state: halted, event: :finish)
    expect(result.value).to eq(6)
  end

  it "fails the Workflow when a signal targets a state with no matching transition" do
    # Build a workflow with TWO external events on DIFFERENT states so that
    # signalling :finish while the FSMSession is at :state_a triggers the
    # "non-external event rejection" guard in fire_event!.
    workflow = Phronomy::Workflow.define(WorkflowAdmissionContext) do
      initial :state_a
      state :state_a
      state :state_b
      state :done
      transition from: :state_a, on: :go_to_b, to: :state_b
      transition from: :state_b, on: :finish, to: :done
      transition from: :done, to: :__finish__
    end

    event_loop = Phronomy::Runtime.instance.event_loop
    task = workflow.invoke_async({value: 0}, config: {workflow_instance_id: "bad-signal"})
    eventually { event_loop.workflow_admission_fsm_session_id("bad-signal") }

    # :finish is defined for :state_b but the FSMSession is at :state_a.
    # The transition fires, fails, and the ArgumentError is propagated.
    workflow.signal(workflow_instance_id: "bad-signal", event: :finish)

    expect { task.wait_result }.to raise_error(ArgumentError, /Transition from/)
    expect(event_loop.workflow_admission_owner("bad-signal")).to be_nil
  end
end
