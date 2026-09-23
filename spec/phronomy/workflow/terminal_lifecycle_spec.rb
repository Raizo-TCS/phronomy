# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Workflow terminal lifecycle through Runtime" do
  let(:persistence) { Phronomy::Persistence.in_memory }
  let(:stored) { persistence.workflow_states }
  let(:runtime) { Phronomy::Runtime.instance }
  let(:registry) { Phronomy::WorkflowExecutionRegistry.for(runtime.event_loop) }
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, default: 0
    end
  end
  let(:workflow) do
    Phronomy::Workflow.define(context_class, persistence: persistence) do
      initial :waiting
      state :waiting
      transition from: :waiting, on: :finish, to: :__finish__
    end
  end

  def eventually
    Timeout.timeout(2) do
      loop do
        value = yield
        return value if value
        sleep 0.005
      end
    end
  end

  def result_of(task)
    Timeout.timeout(2) { task.wait_result }
  end

  def begin_waiting(id)
    task = workflow.invoke_async({}, config: {workflow_instance_id: id})
    fsm_id = eventually { registry.workflow_admission_fsm_session_id(id) }
    [task, fsm_id]
  end

  it "returns the original error and releases admission when F1 proves non-commit" do
    repository = stored
    original = IOError.new("save did not commit")
    expect(repository).to receive(:save).once.and_raise(original)
    task, fsm_id = begin_waiting("pre-state")
    workflow.signal(workflow_instance_id: "pre-state", event: :finish)
    expect { result_of(task) }.to raise_error { |error| expect(error).to equal(original) }
    expect(registry.workflow_admission_owner("pre-state")).to be_nil
    expect(runtime.event_loop.admitted_fsm_session?(fsm_id)).to be(false)
    expect(repository.load("pre-state")).to be_nil
  end

  %i[conflict unreadable].each do |readback|
    it "retains unresolved #{readback} ownership until shutdown without settling the caller" do
      repository = stored
      expect(repository).to receive(:save).once.and_raise(IOError.new("commit outcome lost"))
      task, fsm_id = begin_waiting("unresolved-#{readback}")
      id = "unresolved-#{readback}"
      owner = registry.workflow_admission_owner(id)
      if readback == :conflict
        expect(repository).to receive(:load).with(id).once.and_return(
          revision: 1, snapshot: {fields: {value: 99}, phase: "__end__"}
        )
      else
        expect(repository).to receive(:load).with(id).once.and_raise(IOError.new("cannot read"))
      end
      workflow.signal(workflow_instance_id: id, event: :finish)
      eventually { registry.workflow_admission_state(id) == :recovery_required }
      expect(registry.workflow_admission_owner(id)).to equal(owner)
      expect(registry.workflow_admission_fsm_session_id(id)).to be_nil
      expect(runtime.event_loop.admitted_fsm_session?(fsm_id)).to be(false)
      expect(task.status).to eq(:pending)
      competitor = workflow.invoke_async({}, config: {workflow_instance_id: id})
      expect { result_of(competitor) }.to raise_error(Phronomy::Error, /live execution segment/)

      expect(runtime.shutdown(timeout: 2).cleanup_complete?).to be(true)
      expect(registry.workflow_admission_owner(id)).to be_nil
      expect(task.status).to eq(:pending)
    end
  end

  it "does not let a retired session sink affect a new incarnation of the same Workflow" do
    runner = workflow.instance_variable_get(:@runner)
    sessions = Queue.new
    allow(runner).to receive(:build_session_for).and_wrap_original do |build, **options|
      build.call(**options).tap { |session| sessions << session }
    end
    first, first_id = begin_waiting("reused")
    first_session = Timeout.timeout(2) { sessions.pop }
    workflow.signal(workflow_instance_id: "reused", event: :finish)
    result_of(first)

    second, second_id = begin_waiting("reused")
    expect(second_id).not_to eq(first_id)
    stale = Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
      outcome: :known_failure, revision: nil, error: RuntimeError.new("stale failure")
    )
    expect(first_session.event_sink.post(:workflow_terminal_persistence_result, stale)).to be(false)
    expect(second.status).to eq(:pending)
    expect(registry.workflow_admission_fsm_session_id("reused")).to eq(second_id)
    workflow.signal(workflow_instance_id: "reused", event: :finish)
    expect(result_of(second).value).to eq(0)
    expect(stored.load("reused")[:revision]).to eq(2)
  end

  it "releases admission when terminal submission fails before an operation is queued" do
    task, fsm_id = begin_waiting("submission")
    original = Phronomy::RuntimeShutdownError.new("offload rejected submission")
    allow(runtime.offload).to receive(:submit).and_raise(original)
    workflow.signal(workflow_instance_id: "submission", event: :finish)
    expect { result_of(task) }.to raise_error { |error| expect(error).to equal(original) }
    expect(registry.workflow_admission_owner("submission")).to be_nil
    expect(runtime.event_loop.admitted_fsm_session?(fsm_id)).to be(false)
    expect(stored.load("submission")).to be_nil
  end
end
