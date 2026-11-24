# frozen_string_literal: true

require "spec_helper"

module WorkflowTerminalPersistenceSpec
  # Control only transport scheduling; registry ownership and terminal evidence
  # use the production receivers and tasks.
  class Mailbox
    def initialize
      @owner = Thread.current
      @mutex = Mutex.new
      @messages = []
    end

    def current? = Thread.current.equal?(@owner)

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    def admit(_receiver, &block)
      synchronize(&block)
    end

    def post(receiver, message, admission:, completion:)
      @messages << [receiver, message, completion]
      true
    end

    def deliver_pending
      messages = @messages
      @messages = []
      messages.each do |receiver, message, completion|
        receiver.deliver(message)
        completion&.complete(true)
      end
    end
  end
end

RSpec.describe "WorkflowRunner terminal persistence" do
  Repository = Struct.new(:record) do
    def load(_workflow_instance_id)
      record
    end
  end

  def operation(record:, expected_revision:, snapshot:)
    Phronomy::WorkflowRunner::WorkflowTerminalPersistenceCommand.new(
      repository: Repository.new(record),
      workflow_instance_id: "wf-1",
      expected_revision: expected_revision,
      snapshot: snapshot
    )
  end

  it "classifies F1 as committed when authoritative state equals intended post-state" do
    intended = {fields: {value: 2}, phase: "done"}
    op = operation(
      record: {revision: 3, snapshot: intended},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(
      :reconcile_workflow_terminal_f1,
      op,
      RuntimeError.new("response lost")
    )

    expect(result.outcome).to eq(:success)
    expect(result.revision).to eq(3)
  end

  it "classifies F1 as known failure when authoritative state remains at expected pre-state" do
    intended = {fields: {value: 2}, phase: "done"}
    error = RuntimeError.new("response lost")
    op = operation(
      record: {revision: 2, snapshot: {fields: {value: 1}, phase: "wait"}},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(:reconcile_workflow_terminal_f1, op, error)

    expect(result.outcome).to eq(:known_failure)
    expect(result.error).to equal(error)
  end

  it "keeps F1 unresolved when authoritative state matches neither pre nor intended post" do
    intended = {fields: {value: 2}, phase: "done"}
    op = operation(
      record: {revision: 3, snapshot: {fields: {value: 99}, phase: "done"}},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(
      :reconcile_workflow_terminal_f1,
      op,
      RuntimeError.new("response lost")
    )

    expect(result.outcome).to eq(:outcome_unknown)
    expect(result.error).to be_a(Phronomy::Persistence::ConflictError)
  end

  it "keeps an identical snapshot at a later revision unresolved" do
    intended = {fields: {value: 2}, phase: "done"}
    op = operation(
      record: {revision: 4, snapshot: intended},
      expected_revision: 2,
      snapshot: intended
    )
    runner = Phronomy::WorkflowRunner.allocate

    result = runner.send(:reconcile_workflow_terminal_f1, op, IOError.new("response lost"))

    expect(result.outcome).to eq(:outcome_unknown)
    expect(result.revision).to be_nil
    expect(result.error).to be_a(Phronomy::Persistence::StateConflictError)
  end
end

RSpec.describe "Workflow terminal save submission contract" do
  let(:runner) { Phronomy::WorkflowRunner.allocate }
  let(:repository) { double("Workflow repository") }
  let(:fields) { {value: [+"answer"]} }
  let(:snapshot) { {fields: {value: ["answer"]}, phase: "__end__"} }
  let(:context) { double("Workflow context", to_h: fields, phase: :__end__) }
  let(:sink) { double("Session event sink") }
  let(:stages) { {} }
  let(:delivered) { [] }
  let(:mailbox) { WorkflowTerminalPersistenceSpec::Mailbox.new }
  let(:registry) { Phronomy::WorkflowExecutionRegistry.new(channel: mailbox) }
  let(:environment) { instance_double(Phronomy::WorkflowExecutionEnvironment, executing?: true, registry: registry) }
  let(:offload_task) { Phronomy::Concurrency::PhysicalCompletionTask.new(name: "terminal-save") }
  let(:result_task) { Phronomy::TaskResult.deferred(name: "workflow-result") }
  let(:owner) { Object.new.freeze }

  before do
    runner.instance_variable_set(:@environment, environment)
    runner.instance_variable_set(:@recovery_identity, Object.new.freeze)
    registry.admit_workflow("workflow-save", owner_token: owner)
    registry.bind_workflow_session("workflow-save", owner_token: owner, fsm_session_id: "terminal-session")
    expect(environment).to receive(:submit).with(on_full: :raise) do |&work|
      expect(registry.terminal_operation(owner)).to be_a(Phronomy::WorkflowTerminalOperation)
      stages[:work] = work
      offload_task
    end
    allow(sink).to receive(:post) do |event, result|
      delivered << [event, result]
      true
    end
    execution = Phronomy::WorkflowRunner::Execution.new(
      context: context, workflow_instance_id: "workflow-save", owner_token: owner,
      recursion_limit: 10, repository: repository, persist: true, expected_revision: 8,
      result_task: result_task
    )
    expect(runner.send(:begin_terminal_persistence_on_event_loop,
      execution, terminal_type: :finished, context: context, event_sink: sink)).to eq(:finished)
    expect(registry.workflow_admission_state("workflow-save")).to eq(:persisting_terminal)
    expect(delivered).to be_empty
  end

  def finish_operation
    result = stages.fetch(:work).call
    expect(delivered).to be_empty
    offload_task.mark_physical_complete!
    mailbox.deliver_pending
    expect(delivered).to be_empty
    offload_task.complete(result)
    expect(delivered).to be_empty
    mailbox.deliver_pending
    expect(delivered.size).to eq(1)
    expect(delivered.first.first).to eq(:workflow_terminal_persistence_result)
    expect(delivered.first.last).to equal(result)
    result
  end

  it "saves one immutable snapshot and publishes success only through the session sink" do
    fields[:value].first.replace("mutated after submission")
    expect(repository).to receive(:save).with("workflow-save", expected_revision: 8, snapshot: snapshot) do |_id, **options|
      captured = options.fetch(:snapshot)
      expect(captured).to be_frozen
      expect(captured[:fields][:value]).to be_frozen
      expect(captured[:fields][:value].first).to be_frozen
      9
    end.once
    expect(repository).not_to receive(:load)
    result = finish_operation
    expect(result.to_h).to eq(outcome: :success, revision: 9, error: nil)
  end

  [Phronomy::Persistence::ConflictError, Phronomy::Persistence::NotFoundError,
    Phronomy::Persistence::SerializationError, Phronomy::Persistence::UnsupportedBackendError].each do |error_class|
    it "preserves #{error_class.name} as known failure without readback or retry" do
      failure = error_class.new("save failed")
      expect(repository).to receive(:save).once.and_raise(failure)
      expect(repository).not_to receive(:load)
      result = finish_operation
      expect(result.to_h).to eq(outcome: :known_failure, revision: nil, error: failure)
    end
  end

  it "reconciles an F1 lost response to the exact committed post-state without saving again" do
    expect(repository).to receive(:save).once.and_raise(IOError.new("response lost"))
    expect(repository).to receive(:load).with("workflow-save").once
      .and_return(revision: 9, snapshot: snapshot)
    expect(finish_operation.to_h).to eq(outcome: :success, revision: 9, error: nil)
  end

  it "preserves the original error when F1 readback proves the pre-state" do
    original = IOError.new("response lost")
    expect(repository).to receive(:save).once.and_raise(original)
    expect(repository).to receive(:load).with("workflow-save").once
      .and_return(revision: 8, snapshot: {fields: {value: []}, phase: "wait"})
    expect(finish_operation.to_h).to eq(outcome: :known_failure, revision: nil, error: original)
  end

  it "keeps an F1 conflicting readback uncertain without an automatic retry" do
    expect(repository).to receive(:save).once.and_raise(IOError.new("response lost"))
    expect(repository).to receive(:load).with("workflow-save").once
      .and_return(revision: 9, snapshot: {fields: {value: ["other"]}, phase: "__end__"})
    result = finish_operation
    expect(result.outcome).to eq(:outcome_unknown)
    expect(result.revision).to be_nil
    expect(result.error).to be_a(Phronomy::Persistence::ConflictError)
    expect(result.error.message).to include("conflicts with both expected pre-state and intended post-state")
  end

  it "preserves the readback error when an F1 reconciliation read fails" do
    unreadable = IOError.new("read failed")
    expect(repository).to receive(:save).once.and_raise(IOError.new("response lost"))
    expect(repository).to receive(:load).with("workflow-save").once.and_raise(unreadable)
    expect(finish_operation.to_h).to eq(outcome: :outcome_unknown, revision: nil, error: unreadable)
  end

  it "publishes logical offload failure as uncertain while physical completion remains unproven" do
    failure = RuntimeError.new("worker completion failed")
    expect(repository).not_to receive(:save)
    expect(repository).not_to receive(:load)
    offload_task.fail(failure)
    expect(delivered).to be_empty
    mailbox.deliver_pending
    expect(delivered.map(&:first)).to eq([:workflow_terminal_persistence_result])
    expect(delivered.first.last.to_h).to eq(outcome: :outcome_unknown, revision: nil, error: failure)
    expect(registry.terminal_operation(owner).pending?).to be(true)
    expect(registry.workflow_admission_owner("workflow-save")).to equal(owner)
    expect(registry.release_workflow("workflow-save", owner_token: owner)).to be(false)
    offload_task.mark_physical_complete!
    mailbox.deliver_pending
    expect(delivered.size).to eq(1)
  end

  it "retains a recovery capability and requests retirement when the session rejects delivery" do
    expect(repository).to receive(:save).once.and_return(9)
    expect(repository).not_to receive(:load)
    result = stages.fetch(:work).call
    expect(sink).to receive(:post).with(:workflow_terminal_persistence_result, result).once.and_return(false)
    expect(environment).to receive(:retire_session).with(
      fsm_session_id: "terminal-session", error: an_instance_of(Phronomy::Error)
    ).once
    offload_task.mark_physical_complete!
    offload_task.complete(result)
    mailbox.deliver_pending

    operation = registry.terminal_operation(owner)
    expect(operation.pending?).to be(true)
    expect(registry.workflow_admission_owner("workflow-save")).to equal(owner)
    expect(registry.release_workflow("workflow-save", owner_token: owner)).to be(false)
    expect { result_task.wait_result(timeout: 1) }.to raise_error(Phronomy::WorkflowTerminalRecoveryError) do |error|
      expect(error.recovery).to equal(operation.recovery)
      expect(error.workflow_instance_id).to eq("workflow-save")
      expect(error.recovery_id).to eq(operation.recovery_id)
    end
  end
end
