# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Native terminal child custody acknowledgement" do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:child_class) do
    Class.new(Phronomy::Agent::Base) { agent_definition id: "acknowledged-child", version: 1 }
  end
  let(:parent_class) do
    child_type = child_class
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "acknowledging-parent", version: 1
      subagent :worker, child_type
    end
  end
  let(:parent) { parent_class.create(agent_id: "ack-parent", persistence: stores.agent, coordination_store: stores.multi_agent) }
  let(:child) { child_class.create(agent_id: "ack-child", persistence: stores.agent) }
  let(:participant) { Phronomy::MultiAgent::DurableSubagentCoordinator.new(agent_class: parent_class, persistence: stores.multi_agent) }
  let(:parent_id) { "ack-parent-run" }
  let(:child_id) { "ack-child-run" }
  let(:slot_id) { "ack-slot" }
  let(:owner) { {"kind" => "subagent", "parent_agent_id" => parent.agent_id, "parent_execution_id" => parent_id, "slot" => slot_id} }
  let(:parent_hold) { Phronomy::Agent::Retention.new(agent_id: parent.agent_id, execution_id: parent_id, owner_key: "subagent:#{parent_id}") }
  let(:child_hold) { Phronomy::Agent::Retention.new(agent_id: child.agent_id, execution_id: child_id, owner_key: "subagent:#{parent_id}") }

  after { Phronomy.reset_runtime! }

  def start_record(agent, id, metadata)
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, kind: :input_received, channel: :external)
    value = Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root, input_record: input,
      execution_id: id, metadata: metadata).with(status: :active, phase: :dispatching_tools)
    stores.agent.executions.create_active(value)
    value
  end

  def prepare_records(child_status: :failed, correlation: owner, imported: false)
    child
    unless child_status == :absent
      value = start_record(child, child_id, {"reservation" => correlation})
      if child_status != :active
        failure = {"class" => "IOError", "message" => "child failed", "code" => "child.failure"}
        value = value.with(status: child_status, phase: child_status,
          result_ref: (child_status == :completed) ? stores.agent.contents.put_text("child output") : nil,
          error_ref: (%i[failed cancelled].include?(child_status) ? stores.agent.contents.put_json(failure) : nil))
        stores.agent.executions.save(child_id, expected_revision: value.execution_revision - 1, execution: value)
      end
    end
    entry = {"slot" => slot_id, "name" => "worker", "agent_id" => child.agent_id,
             "execution_id" => child_id, "definition" => child_class.agent_definition.transform_keys(&:to_s),
             "on_error" => "raise", "imported" => imported}
    ref = stores.multi_agent.contents.put_json("children" => [entry], "cancel_requested" => false)
    extension = participant.binding.with(state_ref: ref)
    @parent_record = start_record(parent, parent_id, {"execution_extension" => extension.to_h})
    stores.agent.retain(parent_hold)
    stores.agent.retain(child_hold)
  end

  # Use the real participant, ExecutionChange and transaction coordinator. The
  # small writer isolates persistence contracts from the separate Runtime tests.
  def terminal_change(finishing: true, recovering: false, cancelled: false)
    error = if recovering
      Phronomy::ExecutionRehydrationRequiredError.new("parent needs recovery")
    elsif finishing
      IOError.new("independent parent failure")
    end
    view = Struct.new(:phase, :handoff, :cancel_requested, :callback_failure,
      :source_error, :block_error, :invocation_error)
      .new(phase: finishing ? :failed : :suspended, cancel_requested: cancelled, invocation_error: error)
    record = @parent_record
    Phronomy::Agent::ExecutionChange.new(agent: parent, current: record, root: parent.agent_root,
      kind: :terminal, terminal: view, config: {phronomy_execution_participant: participant}) do |records, state, _receipt, pending|
      status = if pending
        :active
      elsif finishing
        :failed
      else
        :suspended
      end
      updated = record.with(status: status, phase: status, metadata: record.metadata.merge("execution_extension" => state.to_h))
      records.executions.save(record.execution_id, expected_revision: record.execution_revision, execution: updated)
      updated
    end
  end

  def saved_slot(execution_id = parent_id)
    extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: execution_id,
      binding_key: "phronomy.subagent")
    stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children").first
  end

  def pair_completed?
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: child.agent_id, execution_id: child_id, correlation: owner)
    stores.coordinator.atomic do |scope|
      participant.completed_child_pair?(parent.agent_id, parent_id, reservation, live_child: child, scope: scope)
    end
  end

  def rewrite_slot
    record = stores.agent.executions.load(parent_id)
    extension = Phronomy::Agent::ExecutionExtensionState.from_h(record.metadata.fetch("execution_extension"))
    snapshot = stores.multi_agent.contents.fetch_json(extension.state_ref)
    snapshot = Marshal.load(Marshal.dump(snapshot))
    yield snapshot.fetch("children").first
    extension = extension.with(state_ref: stores.multi_agent.contents.put_json(snapshot))
    stores.agent.executions.save(parent_id, expected_revision: record.execution_revision,
      execution: record.with(metadata: record.metadata.merge("execution_extension" => extension.to_h)))
  end

  def structured_child_output(value)
    record = stores.agent.executions.load(child_id)
    stores.agent.executions.save(child_id, expected_revision: record.execution_revision,
      execution: record.with(result_ref: stores.agent.contents.put_text(JSON.generate(value)),
        metadata: record.metadata.merge("result_format" => "json")))
  end

  def add_earlier_history(child_status: :failed, imported: false)
    earlier = child_class.create(agent_id: "earlier-child", persistence: stores.agent)
    earlier_parent_id = "earlier-parent-run"
    earlier_child_id = "earlier-child-run"
    correlation = owner.merge("parent_execution_id" => earlier_parent_id)
    value = start_record(earlier, earlier_child_id, {"reservation" => correlation})
    if child_status != :active
      stores.agent.executions.save(earlier_child_id, expected_revision: value.execution_revision,
        execution: value.with(status: child_status, phase: child_status))
    end
    entry = saved_slot.except("terminal_acknowledgement").merge("agent_id" => earlier.agent_id,
      "execution_id" => earlier_child_id, "imported" => imported)
    ref = stores.multi_agent.contents.put_json("children" => [entry], "cancel_requested" => false)
    extension = participant.binding.with(state_ref: ref)
    @parent_record = start_record(parent, earlier_parent_id, {"execution_extension" => extension.to_h})
    stores.agent.retain(Phronomy::Agent::Retention.new(agent_id: earlier.agent_id,
      execution_id: earlier_child_id, owner_key: "subagent:#{earlier_parent_id}"))
    terminal_change.perform
    [earlier, earlier_child_id, earlier_parent_id]
  end

  %i[completed failed cancelled rejected blocked handed_off].each do |status|
    it "acknowledges exact #{status} child custody without claiming business import" do
      prepare_records(child_status: status)
      terminal_change.perform
      entry = saved_slot
      expect(entry.fetch("imported")).to be(false)
      expect(entry.fetch("terminal_acknowledgement")).to include("version" => 1,
        "agent_id" => child.agent_id, "execution_id" => child_id, "reservation" => owner, "status" => status.to_s)
      expect(pair_completed?).to be(true)
      expect(stores.agent.retained_references(agent_id: parent.agent_id)).to eq([parent_hold])
      expect(stores.agent.retained_references(agent_id: child.agent_id)).to eq([child_hold])
    end
  end

  %i[active suspended absent].each do |status|
    it "does not acknowledge #{status} child custody" do
      prepare_records(child_status: status)
      terminal_change(cancelled: true).perform
      expect(saved_slot).not_to have_key("terminal_acknowledgement")
      expect(pair_completed?).to be(false)
    end
  end

  it "does not acknowledge a suspended parent transition" do
    prepare_records
    terminal_change(finishing: false).perform
    expect(saved_slot).not_to have_key("terminal_acknowledgement")
  end

  it "does not acknowledge a parent transition requiring rehydration" do
    prepare_records
    terminal_change(recovering: true).perform
    expect(saved_slot).not_to have_key("terminal_acknowledgement")
  end

  it "keeps an existing imported slot unchanged" do
    prepare_records(imported: true)
    terminal_change.perform
    expect(saved_slot.fetch("imported")).to be(true)
    expect(saved_slot).not_to have_key("terminal_acknowledgement")
    expect(pair_completed?).to be(true)
  end

  it "does not invent an acknowledgement for a preexisting terminal parent" do
    prepare_records
    stores.agent.executions.save(parent_id, expected_revision: @parent_record.execution_revision,
      execution: @parent_record.with(status: :failed, phase: :failed))
    expect(saved_slot.fetch("imported")).to be(false)
    expect(saved_slot).not_to have_key("terminal_acknowledgement")
    expect(pair_completed?).to be(false)
    expect(stores.agent.retained_references(agent_id: parent.agent_id)).to eq([parent_hold])
    expect(stores.agent.retained_references(agent_id: child.agent_id)).to eq([child_hold])
  end

  %w[kind parent_agent_id parent_execution_id slot].each do |field|
    it "does not acknowledge a child with another reservation #{field}" do
      prepare_records(correlation: owner.merge(field => "another"))
      terminal_change.perform
      expect(saved_slot).not_to have_key("terminal_acknowledgement")
      expect(pair_completed?).to be(false)
    end
  end

  {"version" => 2, "agent_id" => "other-child", "execution_id" => "other-run",
   "status" => "completed", "outcome_digest" => "0" * 64,
   "reservation" => {"kind" => "unrelated"}}.each do |field, replacement|
    it "rejects a changed acknowledgement #{field} during pair validation" do
      prepare_records
      terminal_change.perform
      rewrite_slot { |entry| entry.fetch("terminal_acknowledgement")[field] = replacement }
      expect(pair_completed?).to be(false)
    end
  end

  it "rejects a changed durable terminal outcome after acknowledgement" do
    prepare_records
    terminal_change.perform
    record = stores.agent.executions.load(child_id)
    stores.agent.executions.save(child_id, expected_revision: record.execution_revision,
      execution: record.with(error_ref: stores.agent.contents.put_json("message" => "a different terminal error")))
    expect(pair_completed?).to be(false)
  end

  it "supports structured output integers beyond the canonical metadata range and negative zero" do
    prepare_records(child_status: :completed)
    value = {"large" => 2**80, "nested" => [{"zero" => -0.0}]}
    structured_child_output(value)
    terminal_change.perform
    expect(pair_completed?).to be(true)
    observed = stores.agent.observe_execution(agent_id: child.agent_id, execution_id: child_id)
    expect(observed.result.fetch("large")).to eq(2**80)
    expect(1.0 / observed.result.fetch("nested").first.fetch("zero")).to eq(-Float::INFINITY)
  end

  it "treats object key ordering as the same terminal outcome" do
    prepare_records(child_status: :completed)
    structured_child_output({"z" => [{"b" => 2, "a" => 1}], "a" => true})
    terminal_change.perform
    structured_child_output({"a" => true, "z" => [{"a" => 1, "b" => 2}]})
    expect(pair_completed?).to be(true)
  end

  it "distinguishes JSON number types when validating a retained terminal outcome" do
    prepare_records(child_status: :completed)
    structured_child_output({"number" => 1})
    terminal_change.perform
    structured_child_output({"number" => 1.0})
    expect(pair_completed?).to be(false)
  end

  it "preserves historical acknowledgement across a later cancellation request" do
    prepare_records
    terminal_change.perform
    original = saved_slot.fetch("terminal_acknowledgement")
    stores.agent.request_cancellation(agent_id: child.agent_id, execution_id: child_id)
    expect(pair_completed?).to be(true)
    expect(saved_slot.fetch("terminal_acknowledgement")).to eq(original)
  end

  it "does not release a pair with an additional child history owner" do
    prepare_records
    terminal_change.perform
    stores.agent.retain(Phronomy::Agent::Retention.new(agent_id: child.agent_id, owner_key: "another-owner"))
    expect(pair_completed?).to be(false)
  end

  it "permits earlier acknowledged history without deleting either parent retention" do
    prepare_records
    terminal_change.perform
    _earlier, _id, previous = add_earlier_history
    expect(saved_slot(previous).fetch("imported")).to be(false)
    expect(saved_slot(previous)).to have_key("terminal_acknowledgement")
    expect(pair_completed?).to be(true)
    expect(stores.agent.retained_references(agent_id: parent.agent_id).map(&:execution_id))
      .to contain_exactly(parent_id, previous)
  end

  it "preserves the existing earlier imported-history release rule" do
    prepare_records
    terminal_change.perform
    _earlier, _id, previous = add_earlier_history(imported: true)
    expect(saved_slot(previous)).not_to have_key("terminal_acknowledgement")
    expect(pair_completed?).to be(true)
  end

  it "refuses release when earlier history still owns an unacknowledged active child" do
    prepare_records
    terminal_change.perform
    _earlier, _id, previous = add_earlier_history(child_status: :active)
    expect(saved_slot(previous)).not_to have_key("terminal_acknowledgement")
    expect(pair_completed?).to be(false)
  end

  it "revalidates the exact outcome of earlier acknowledged history" do
    prepare_records
    terminal_change.perform
    _earlier, id, _previous = add_earlier_history
    record = stores.agent.executions.load(id)
    stores.agent.executions.save(id, expected_revision: record.execution_revision,
      execution: record.with(error_ref: stores.agent.contents.put_json("message" => "changed earlier failure")))
    expect(pair_completed?).to be(false)
  end

  %i[rollback committed].each do |disposition|
    it "proves #{disposition} parent acknowledgement after losing the transaction response" do
      prepare_records
      armed = true
      allow(stores.coordinator).to receive(:atomic).and_wrap_original do |original, &transaction|
        if armed
          armed = false
          result = original.call do |scope|
            value = transaction.call(scope)
            raise IOError, "parent save rolled back" if disposition == :rollback
            value
          end
          raise IOError, "parent save response lost" if disposition == :committed
          result
        else
          original.call(&transaction)
        end
      end
      change = terminal_change
      if disposition == :rollback
        expect { change.perform }.to raise_error(IOError, "parent save rolled back")
        expect(stores.agent.executions.load(parent_id).to_h).to eq(@parent_record.to_h)
        expect(saved_slot).not_to have_key("terminal_acknowledgement")
      else
        expect(change.perform.status).to eq(:failed)
        expect(saved_slot).to have_key("terminal_acknowledgement")
        expect(pair_completed?).to be(true)
      end
      expect(stores.agent.retained_references(agent_id: child.agent_id)).to eq([child_hold])
    end
  end

  it "reports unknown when the committed parent acknowledgement cannot be read back" do
    prepare_records
    changes = 0
    allow(participant).to receive(:change_evidence).and_wrap_original do |original, *arguments|
      changes += 1
      raise IOError, "parent proof unavailable" if changes == 3
      original.call(*arguments)
    end
    allow(participant).to receive(:commit).and_wrap_original do |original, change|
      original.call(change)
      raise IOError, "parent commit response lost"
    end
    expect { terminal_change.perform }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /outcome is unknown/)
    expect(stores.agent.executions.load(parent_id).status).to eq(:failed)
    expect(saved_slot).to have_key("terminal_acknowledgement")
    expect(stores.agent.retained_references(agent_id: child.agent_id)).to eq([child_hold])
  end

  it "proves the historical parent commit even if another owner subsequently retains the child" do
    prepare_records
    extra = Phronomy::Agent::Retention.new(agent_id: child.agent_id, owner_key: "later-history-owner")
    allow(participant).to receive(:commit).and_wrap_original do |original, change|
      original.call(change)
      stores.agent.retain(extra)
      raise IOError, "parent commit response lost"
    end
    expect(terminal_change.perform.status).to eq(:failed)
    expect(saved_slot).to have_key("terminal_acknowledgement")
    expect(stores.agent.retained_references(agent_id: child.agent_id)).to contain_exactly(child_hold, extra)
    expect(pair_completed?).to be(false)
  end
end
