# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::HandoffDispatchEvidence do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:persistence) { stores.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-proof-agent", version: 1
      model "offline-model"
    end
  end
  let(:main) { agent_class.create(agent_id: "handoff-main", persistence: persistence) }
  let(:target) { agent_class.create(agent_id: "handoff-target", persistence: persistence) }
  let(:active) { main }
  let(:transfer_source) { main }
  let(:phase) { "stable" }
  let(:expected_revision) { 1 }
  let(:owner) { {"kind" => "handoff", "main_agent_id" => main.agent_id} }
  let(:owner_key) { "handoff:#{main.agent_id}" }
  let(:participant) do
    Phronomy::MultiAgent::HandoffParticipant.new(persistence: stores.multi_agent,
      main_agent_id: main.agent_id, expected_revision: expected_revision)
  end
  let(:routing) do
    Phronomy::MultiAgent::HandoffState.new(main_agent_id: main.agent_id, handoff_revision: 1,
      active_agent_id: active.agent_id, active_handoff_context_ref: (phase == "stable") ? nil : "captured-context",
      phase: phase, pending_source_execution_id: (phase == "stable") ? nil : "handoff-source-run",
      pending_target_execution_id: (phase == "stable") ? nil : execution.execution_id,
      created_at: "2026-11-28T00:00:00.000000Z", updated_at: "2026-11-28T00:00:00.000000Z",
      metadata: {"retained_agent_ids" => [main.agent_id, active.agent_id].uniq,
                 "source_agent_id" => transfer_source.agent_id, "target_definition" => agent_class.agent_definition.transform_keys(&:to_s)})
  end
  let(:execution) { build_execution(active, "handoff-proof-run") }

  def build_execution(agent, id)
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: id,
      kind: :external_message, channel: :llm, role: :user,
      content_ref: persistence.contents.put_text("input"), context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root, input_record: input,
      execution_id: id).with(status: :active,
        metadata: {"execution_extension" => participant.binding.to_h, "reservation" => owner})
  end

  before do
    persistence.transaction { |records| records.executions.create_active(execution) }
    persistence.retain(Phronomy::Agent::Retention.new(agent_id: main.agent_id, owner_key: owner_key))
    unless active.equal?(main)
      persistence.retain(Phronomy::Agent::Retention.new(agent_id: active.agent_id,
        execution_id: (phase == "stable") ? "previous-target-turn" : execution.execution_id, owner_key: owner_key))
    end
    stores.multi_agent.transaction do |records|
      records.handoff_states.save(main.agent_id, expected_revision: nil, state: routing)
    end
  end

  def change_for
    Phronomy::Agent::ExecutionChange.new(agent: active, current: execution, root: active.agent_root,
      kind: :dispatch, updated: execution.with(phase: :dispatching_tools),
      config: {phronomy_execution_participant: participant})
  end

  def capture(rollback: false)
    change = change_for
    if rollback
      armed = true
      allow(persistence.coordinator).to receive(:atomic).and_wrap_original do |original, &body|
        if armed
          armed = false
          original.call do |scope|
            body.call(scope)
            raise IOError, "Handoff dispatch rollback"
          end
        else
          original.call(&body)
        end
      end
      expect { change.perform }.to raise_error(IOError, "Handoff dispatch rollback")
      allow(persistence.coordinator).to receive(:atomic).and_call_original
    else
      change.perform
    end
    @captured_values = change.captured_evidence
    Phronomy::Agent::DispatchPersistenceEvidence.capture(change, persistence: persistence,
      kind: :tool, participant: participant)
  end

  def adapter(values = @captured_values, store: persistence)
    described_class.capture(values: values, persistence: store, handoff_persistence: stores.multi_agent,
      main_agent_id: main.agent_id, expected_revision: expected_revision,
      binding_key: Phronomy::MultiAgent::HandoffParticipant::BINDING_KEY)
  end

  def change_routing(**changes)
    stores.multi_agent.transaction do |records|
      current = records.handoff_states.load_locked(main.agent_id)
      records.handoff_states.save(main.agent_id, expected_revision: current.handoff_revision,
        state: current.with(**changes))
    end
  end

  it "retries only the captured Agent save while retaining unchanged routing and holds" do
    proof = capture(rollback: true)
    expect(proof.participation?).to be(true)
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:not_committed)
    expect(participant).not_to receive(:commit)
    expect_any_instance_of(Phronomy::MultiAgent::Persistence::HandoffStateRepository).not_to receive(:save)
    expect(persistence).not_to receive(:retain)
    result = proof.retry(persistence: persistence)
    expect(result.disposition).to eq(:committed), result.read_error&.full_message
    expect(result.continuation_error).to be_nil
    expect(stores.multi_agent.handoff_states.load(main.agent_id).to_h).to eq(routing.to_h)
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
  end

  it "guards routing before acquiring the ordered Agent guards" do
    proof = capture(rollback: true)
    order = []
    allow_any_instance_of(Phronomy::MultiAgent::Persistence::HandoffStateRepository).to receive(:load_locked).and_wrap_original do |original, id|
      order << [:routing, id]
      original.call(id)
    end
    allow(persistence).to receive(:guard_agents).and_wrap_original do |original, scope, agent_ids:|
      order << [:agents, agent_ids]
      original.call(scope, agent_ids: agent_ids)
    end
    expect(proof.retry(persistence: persistence).disposition).to eq(:committed)
    expect(order.first(2)).to eq([[:routing, main.agent_id], [:agents, [main.agent_id]]])
  end

  it "treats retention enumeration order as the same captured fact set" do
    persistence.retain(Phronomy::Agent::Retention.new(agent_id: main.agent_id, owner_key: "audit"))
    proof = capture
    allow(persistence).to receive(:retained_references).and_wrap_original do |original, **options|
      original.call(**options).reverse
    end
    expect(proof.reconcile(persistence: persistence).disposition).to eq(:committed)
  end

  it "keeps an immutable participant footprint after the factory returns" do
    capture
    values = Marshal.load(Marshal.dump(@captured_values.except(:result))).merge(result: @captured_values.fetch(:result))
    proof = adapter(values)
    values.fetch(:before).fetch(1).fetch(0)["active_agent_id"] = "another-agent"
    persistence.coordinator.atomic do |scope|
      proof.guarded_agent_ids(persistence: persistence, scope: scope)
      expect { proof.assert_continuable!(persistence: persistence, scope: scope) }.not_to raise_error
    end
    expect(proof).to be_frozen
  end

  [:routing, :retention].each do |changed|
    it "does not retry after the captured #{changed} footprint changes" do
      proof = capture(rollback: true)
      if changed == :routing
        change_routing(metadata: routing.metadata.merge("audit" => true))
      else
        persistence.retain(Phronomy::Agent::Retention.new(agent_id: main.agent_id, owner_key: "new-owner"))
      end
      expect(persistence.executions).not_to receive(:save)
      expect(proof.retry(persistence: persistence).disposition).to eq(:unknown)
      expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
    end
  end

  it "blocks new continuation when the captured anchor hold is absent" do
    persistence.coordinator.atomic do |scope|
      persistence.release_retention(agent_id: main.agent_id, owner_key: owner_key, scope: scope)
    end
    result = capture.reconcile(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
  end

  it "keeps cancellation distinct from a committed dispatch barrier" do
    persistence.request_cancellation(agent_id: active.agent_id, execution_id: execution.execution_id)
    result = capture.reconcile(persistence: persistence)
    expect(result.disposition).to eq(:committed)
    expect(result.continuation_error).to be_a(Phronomy::CancellationError)
  end

  context "when the participant's original route revision is stale" do
    let(:expected_revision) { 0 }

    it "preserves the observed save but does not authorize continuation" do
      result = capture.reconcile(persistence: persistence)
      expect(result.disposition).to eq(:committed)
      expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
    end
  end

  it "does not turn a failed authoritative read into absence" do
    proof = capture
    allow_any_instance_of(Phronomy::MultiAgent::Persistence::HandoffStateRepository).to receive(:load_locked).and_raise(IOError, "routing unavailable")
    result = proof.reconcile(persistence: persistence)
    expect(result.disposition).to eq(:unknown)
    expect(result.read_error).to be_a(IOError)
  end

  it "rejects an adapter from another Agent Store sharing the coordinator" do
    capture
    other = Phronomy::Agent::Store.new(coordinator: persistence.coordinator, records: Phronomy::Agent::Persistence::Records)
    expect { adapter(store: other) }.to raise_error(Phronomy::Persistence::StateConflictError, /another Store/)
  end

  [:binding, :reservation, :participant].each do |changed|
    it "rejects captured #{changed} facts inconsistent with this Handoff" do
      capture
      values = Marshal.load(Marshal.dump(@captured_values.except(:result))).merge(result: @captured_values.fetch(:result))
      case changed
      when :binding then values.fetch(:before).fetch(0).fetch(1).fetch("metadata").fetch("execution_extension")["binding_key"] = "another.binding"
      when :reservation then values.fetch(:before).fetch(0).fetch(1).fetch("metadata").fetch("reservation")["main_agent_id"] = "another-main"
      when :participant then values.fetch(:after).fetch(1).fetch(0)["handoff_revision"] += 1
      end
      expect { adapter(values) }.to raise_error(Phronomy::Persistence::StateConflictError)
    end
  end

  it "opts in without persistence I/O only for the exact binding, reservation and Store" do
    expect(persistence).not_to receive(:observe_execution)
    expect_any_instance_of(Phronomy::MultiAgent::Persistence::HandoffStateRepository).not_to receive(:load)
    expect(participant.send(:dispatch_recovery_supported?, execution: execution, persistence: persistence)).to be(true)
    different = execution.with(metadata: execution.metadata.merge("reservation" => {"kind" => "handoff", "main_agent_id" => "another"}))
    expect(participant.send(:dispatch_recovery_supported?, execution: different, persistence: persistence)).to be(false)
  end

  context "when a previously transferred Target owns a later stable turn" do
    let(:active) { target }

    it "accepts the existing same-anchor hold without inventing a new exact hold" do
      result = capture(rollback: true).retry(persistence: persistence)
      expect(result.disposition).to eq(:committed)
      expect(result.continuation_error).to be_nil
    end
  end

  context "when the captured route names an exact pending Target" do
    let(:active) { target }
    let(:phase) { "target_pending" }

    before do
      source = build_execution(transfer_source, routing.pending_source_execution_id)
      receipt = {"target_agent_id" => active.agent_id, "target_execution_id" => execution.execution_id,
                 "context_ref" => routing.active_handoff_context_ref, "owner_key" => owner_key}
      persistence.transaction do |records|
        records.executions.create_active(source)
        records.executions.save(source.execution_id, expected_revision: source.execution_revision,
          execution: source.with(status: :handed_off, phase: :handed_off,
            metadata: source.metadata.merge("transfer_receipt" => receipt)))
      end
      persistence.retain(Phronomy::Agent::Retention.new(agent_id: transfer_source.agent_id,
        execution_id: source.execution_id, owner_key: owner_key))
    end

    it "continues only the captured Target of the saved Source transfer" do
      result = capture(rollback: true).retry(persistence: persistence)
      expect(result.disposition).to eq(:committed), result.read_error&.full_message
      expect(result.continuation_error).to be_nil
    end

    it "requires the exact pending Target hold even if a previous turn is retained" do
      persistence.coordinator.atomic do |scope|
        persistence.release_retention(agent_id: active.agent_id, owner_key: owner_key, scope: scope)
        persistence.retain(Phronomy::Agent::Retention.new(agent_id: active.agent_id,
          execution_id: "previous-turn", owner_key: owner_key), scope: scope)
      end
      result = capture.reconcile(persistence: persistence)
      expect(result.disposition).to eq(:committed)
      expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
    end

    it "does not dispatch a Target whose Source receipt identifies a different execution" do
      source = persistence.executions.load(routing.pending_source_execution_id)
      metadata = source.metadata.merge("transfer_receipt" => source.metadata.fetch("transfer_receipt").merge("target_execution_id" => "another-turn"))
      persistence.executions.save(source.execution_id, expected_revision: source.execution_revision,
        execution: source.with(metadata: metadata))
      result = capture.reconcile(persistence: persistence)
      expect(result.disposition).to eq(:committed)
      expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
    end

    context "when the Source is a non-main Agent in a longer chain" do
      let(:transfer_source) { agent_class.create(agent_id: "handoff-between", persistence: persistence) }

      it "guards the Source with the anchor and Target before continuing" do
        proof = capture(rollback: true)
        expect(persistence).to receive(:guard_agents).with(anything,
          agent_ids: [main.agent_id, active.agent_id, transfer_source.agent_id].sort).and_call_original
        result = proof.retry(persistence: persistence)
        expect(result.disposition).to eq(:committed)
        expect(result.continuation_error).to be_nil
      end

      it "does not continue a pending Target after the exact Source hold is removed" do
        persistence.coordinator.atomic do |scope|
          persistence.release_retention(agent_id: transfer_source.agent_id, owner_key: owner_key, scope: scope)
          persistence.retain(Phronomy::Agent::Retention.new(agent_id: transfer_source.agent_id,
            execution_id: "older-source-turn", owner_key: owner_key), scope: scope)
        end
        result = capture.reconcile(persistence: persistence)
        expect(result.disposition).to eq(:committed)
        expect(result.continuation_error).to be_a(Phronomy::Persistence::StateConflictError)
        expect(result.continuation_error.message).to include("Source transfer retention")
      end
    end
  end
end
