# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Captured native parent outcome persistence" do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:persistence) { stores.agent }
  let(:child_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "native-outcome-child", version: 1 } }
  let(:parent_class) do
    worker = child_class
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "native-outcome-parent", version: 1
      subagent :worker, worker
    end
  end
  let(:parent) { parent_class.create(agent_id: "native-outcome-parent", persistence: persistence, coordination_store: stores.multi_agent) }
  let(:participant) { parent.__invocation_config({}).fetch(:phronomy_execution_participant) }
  let(:committer) { Phronomy::Agent::ExecutionOutcomeCommitter.new(agent: parent, persistence: persistence) }
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: parent.agent_id, execution_id: "native-outcome-run",
      kind: :external_message, channel: :llm, role: :user, content_ref: persistence.contents.put_text("input"), context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: parent.agent_root, input_record: input,
      execution_id: "native-outcome-run", metadata: {"execution_extension" => participant.binding.to_h}).with(status: :active)
  end

  before { persistence.executions.create_active(execution) }

  def reserve_child(status: :active)
    updated = execution.with(phase: :dispatching_tools, metadata: execution.metadata.merge(
      Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY => [
        {"tool_invocation_id" => "native-outcome-slot", "tool_name" => "dispatch_to_worker",
         "arguments" => {"input" => "review"}, "status" => "authorized"}
      ]
    ))
    change = Phronomy::Agent::ExecutionChange.new(agent: parent, current: execution, root: parent.agent_root,
      kind: :dispatch, updated: updated, config: {phronomy_execution_participant: participant})
    current = change.perform
    @slot = stores.multi_agent.contents.fetch_json(current.metadata.dig("execution_extension", "state_ref")).fetch("children").first
    @child_hold = Phronomy::Agent::Retention.new(agent_id: @slot.fetch("agent_id"),
      execution_id: @slot.fetch("execution_id"), owner_key: "subagent:#{execution.execution_id}")
    child = child_class.create(agent_id: @slot.fetch("agent_id"), persistence: persistence, retention: @child_hold)
    input = Phronomy::Agent::JournalRecord.new(agent_id: child.agent_id, kind: :input_received, channel: :external)
    @child_record = Phronomy::Agent::AgentExecution.start(agent_root: child.agent_root, input_record: input,
      execution_id: @slot.fetch("execution_id"), metadata: {"reservation" => {
        "kind" => "subagent", "parent_agent_id" => parent.agent_id,
        "parent_execution_id" => execution.execution_id, "slot" => @slot.fetch("slot")
      }}).with(status: :active)
    persistence.executions.create_active(@child_record)
    finish_child(status) unless status == :active
    current
  end

  def finish_child(status = :completed, output: "child completed")
    current = persistence.executions.load(@child_record.execution_id)
    @child_record = current.with(status: status, phase: status, result_ref: persistence.contents.put_text(output))
    persistence.executions.save(current.execution_id, expected_revision: current.execution_revision, execution: @child_record)
  end

  def approval_request
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(tool_invocation_id: "protected-tool",
      tool_call_id: "call-protected", tool_name: "protected_action", arguments: {}, facts: {},
      reason: "Application approval", origin: :local, metadata: {})
    Phronomy::Agent::ToolApprovalRequest.new(execution_id: execution.execution_id, items: [item])
  end

  def command(kind, current: execution)
    error = case kind
    when :coordination_wait then Phronomy::ExecutionRehydrationRequiredError.new("Child still owns work")
    when :failed then IOError.new("Parent business failure")
    end
    view = Phronomy::Agent::ExecutionOutcomeCommitter::TerminalView.new(
      phase: (kind == :suspended) ? :suspended : :completed, output: "parent completed", usage: nil,
      approval_request: (kind == :suspended) ? approval_request : nil, rejected: false,
      input_blocked: false, output_blocked: false, block_error: nil, invocation_error: nil,
      handoff: nil, callback_failure: nil, source_error: error, cancel_requested: false
    )
    Phronomy::Agent::ExecutionOutcomeCommitter::Command.new(execution_id: current.execution_id,
      fsm_session_id: "native-outcome-session", expected_execution_revision: current.execution_revision,
      root: parent.agent_root, journal_records: [].freeze, execution: current,
      runtime_snapshot: {llm_results: [], runtime_events: [], active_call: nil}.freeze,
      terminal_view: view, state_required: true, wiring: {phronomy_execution_participant: participant}.freeze)
  end

  def capture(operation, rollback: false, on_prepared: nil)
    evidence = nil
    if rollback
      armed = true
      allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &transaction|
        if armed
          armed = false
          original.call do |scope|
            transaction.call(scope)
            raise IOError, "native outcome rolled back"
          end
        else
          original.call(&transaction)
        end
      end
      expect { committer.commit_outcome(operation, on_evidence: ->(value) { evidence = value }, on_prepared: on_prepared) }
        .to raise_error(IOError, "native outcome rolled back")
      allow(persistence.coordinator).to receive(:atomic).and_call_original
    else
      committer.commit_outcome(operation, on_evidence: ->(value) { evidence = value }, on_prepared: on_prepared)
    end
    expect(evidence).not_to be_nil
    evidence
  end

  %i[completed failed suspended].each do |kind|
    it "replays the exact captured #{kind} records and native content after rollback" do
      operation = command(kind)
      input = nil
      proof = capture(operation, rollback: true, on_prepared: ->(value) { input = value })
      semantic = input.values.fetch(:result)
      expect(proof.outcome.type).to eq(kind)
      expect(semantic.type).to eq(kind)
      expect(semantic.error).to equal(operation.terminal_view.source_error)
      expect(semantic.approval_request).to equal(operation.terminal_view.approval_request)
      reference = proof.outcome.execution.metadata.dig("execution_extension", "state_ref")
      expect(stores.multi_agent.contents.exist?(reference)).to be(false)
      expect(proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
      expect(participant).not_to receive(:commit)
      expect(Phronomy::Agent::RuntimeRecordEncoder).not_to receive(:encode)
      expect_any_instance_of(Phronomy::Agent::Persistence::JournalRepository).not_to receive(:append) if kind == :suspended
      expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
      expect(persistence.executions.load(execution.execution_id).to_h).to eq(proof.outcome.execution.to_h)
      expect(persistence.agents.load(parent.agent_id).to_h).to eq(proof.outcome.root.to_h)
      expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
      if kind == :suspended
        restored = Phronomy::Agent::ToolApprovalRequest.from_h(proof.outcome.execution.approval_request)
        expect(restored.to_h).to eq(operation.terminal_view.approval_request.to_h)
        expect(semantic.result.fetch(:approval_request)).to equal(operation.terminal_view.approval_request)
        expect(proof.outcome.execution_observation).to be_nil
        expect(proof.outcome.execution.status).to eq(:suspended)
      elsif kind == :completed
        expect(semantic.result.fetch(:output)).to equal(operation.terminal_view.output)
        expect(semantic.result.fetch(:messages)).to be_an(Array)
      end
    end
  end

  it "retries a captured coordination wait after the child finishes without rewriting root or journal" do
    current = reserve_child
    operation = command(:coordination_wait, current: current)
    input = nil
    proof = capture(operation, rollback: true, on_prepared: ->(value) { input = value })
    expect(input.values.fetch(:result).error).to equal(operation.terminal_view.source_error)
    expect(proof.outcome.type).to eq(:coordination_wait)
    expect(proof.outcome.execution_observation).to be_nil
    expect(proof.outcome.execution.status).to eq(:active)
    expect(proof.outcome.root.to_h).to eq(proof.before.fetch(0).fetch(0))
    finish_child
    expect(participant).not_to receive(:commit)
    expect_any_instance_of(Phronomy::Agent::Persistence::JournalRepository).not_to receive(:append)
    expect_any_instance_of(Phronomy::Agent::Persistence::AgentRepository).not_to receive(:save)
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
    snapshot = stores.multi_agent.contents.fetch_json(proof.outcome.execution.metadata.dig("execution_extension", "state_ref"))
    expect(snapshot.fetch("children").first.fetch("imported")).to be(false)
    expect(snapshot.fetch("children").first).not_to have_key("terminal_acknowledgement")
  end

  it "replays cancellation from a suspended parent without repeating participant work" do
    current = reserve_child(status: :completed)
    waiting = capture(command(:suspended, current: current))
    operation = command(:failed, current: waiting.outcome.execution).with(root: waiting.outcome.root)
    operation = operation.with(terminal_view: operation.terminal_view.with(
      source_error: Phronomy::CancellationError.new("Parent cancelled during approval"), cancel_requested: true
    ))
    proof = capture(operation, rollback: true)
    expect(proof.before.fetch(0).fetch(1).fetch("status")).to eq(:suspended)
    expect(proof.outcome.execution.status).to eq(:cancelled)
    expect(participant).not_to receive(:commit)
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(proof.outcome.execution.to_h)
    expect(proof.after.fetch(0).fetch(3).fetch("children").first).to have_key("terminal_acknowledgement")
  end

  it "does not invent a late acknowledgement while retrying an independently failed parent" do
    current = reserve_child
    proof = capture(command(:failed, current: current), rollback: true)
    finish_child
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
    snapshot = stores.multi_agent.contents.fetch_json(proof.outcome.execution.metadata.dig("execution_extension", "state_ref"))
    expect(snapshot.fetch("children").first).not_to have_key("terminal_acknowledgement")
  end

  it "refuses pre-state replay when a captured terminal acknowledgement no longer matches its child" do
    current = reserve_child(status: :completed)
    proof = capture(command(:failed, current: current), rollback: true)
    expect(proof.after.fetch(0).fetch(3).fetch("children").first).to have_key("terminal_acknowledgement")
    finish_child(:completed, output: "illegally changed result")
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:not_committed)
    expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
  end

  it "preserves a committed parent fact after child progress and retention changes" do
    current = reserve_child
    proof = capture(command(:coordination_wait, current: current))
    finish_child
    persistence.coordinator.atomic do |scope|
      persistence.release_retention(agent_id: @slot.fetch("agent_id"), owner_key: @child_hold.owner_key, scope: scope)
    end
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
  end

  it "refuses replay after the required child hold disappears without losing confirmed pre-state" do
    current = reserve_child
    proof = capture(command(:coordination_wait, current: current), rollback: true)
    persistence.coordinator.atomic do |scope|
      persistence.release_retention(agent_id: @slot.fetch("agent_id"), owner_key: @child_hold.owner_key, scope: scope)
    end
    expect_any_instance_of(Phronomy::Agent::Persistence::ExecutionRepository).not_to receive(:save)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:not_committed)
    expect(result.read_error).to be_a(Phronomy::Persistence::StateConflictError)
  end
end
