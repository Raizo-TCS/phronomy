# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::HandoffTerminalFinalization do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:persistence) { stores.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-terminal-proof", version: 1
      model "offline"
    end
  end
  let(:main) { agent_class.create(agent_id: "m-anchor", persistence: persistence) }
  let(:source) { agent_class.create(agent_id: "a-source", persistence: persistence) }
  let(:target) { agent_class.create(agent_id: "z-target", persistence: persistence) }
  let(:owner) { {"kind" => "handoff", "main_agent_id" => main.agent_id} }
  let(:owner_key) { "handoff:#{main.agent_id}" }
  let(:status) { :failed }
  let(:failure) { {"class" => "ArgumentError", "message" => "intake rejected"} }
  let(:routing) do
    Phronomy::MultiAgent::HandoffState.new(main_agent_id: main.agent_id, handoff_revision: 1,
      active_agent_id: target.agent_id, active_handoff_context_ref: "saved-context", phase: "target_pending",
      pending_source_execution_id: "source-run", pending_target_execution_id: "target-run",
      created_at: "2026-11-28T00:00:00.000000Z", updated_at: "2026-11-28T00:00:00.000000Z",
      metadata: {"source_agent_id" => source.agent_id, "retained_agent_ids" => agents.keys})
  end
  let(:agents) { [main, source, target].to_h { |agent| [agent.agent_id, agent] } }
  let(:operation) { described_class.new(persistence: stores.multi_agent, main_agent_id: main.agent_id, agents: agents) }
  let(:saved) { persistence.observe_execution(agent_id: target.agent_id, execution_id: "target-run") }

  def save_execution(agent, id, status, metadata, error = nil)
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: id,
      kind: :external_message, channel: :llm, role: :user,
      content_ref: persistence.contents.put_text("input"), context_candidate: true)
    active = Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: input, execution_id: id).with(status: :active, metadata: metadata.merge("reservation" => owner))
    terminal = active.with(status: status, phase: status, error_ref: error && persistence.contents.put_json(error))
    persistence.transaction do |records|
      records.executions.create_active(active)
      records.executions.save(id, expected_revision: active.execution_revision, execution: terminal)
    end
  end

  before do
    save_execution(source, "source-run", :handed_off,
      {"transfer_receipt" => {"target_agent_id" => target.agent_id, "target_execution_id" => "target-run",
                              "context_ref" => "saved-context", "owner_key" => owner_key}})
    save_execution(target, "target-run", status, {}, failure)
    [[main, nil], [source, "source-run"], [target, "target-run"]].each do |agent, id|
      persistence.retain(Phronomy::Agent::Retention.new(agent_id: agent.agent_id, execution_id: id, owner_key: owner_key))
      allow(agent).to receive(:__execution_custody_pending?).and_return(false)
    end
    stores.multi_agent.transaction { |records| records.handoff_states.save(main.agent_id, expected_revision: nil, state: routing) }
  end

  def finalize(op = operation)
    op.call(execution_id: "chain-entry", target: saved)
  end

  def current_route
    stores.multi_agent.handoff_states.load(main.agent_id)
  end

  def change_route(**changes)
    stores.multi_agent.transaction do |records|
      current = records.handoff_states.load_locked(main.agent_id)
      records.handoff_states.save(main.agent_id, expected_revision: current.handoff_revision, state: current.with(**changes))
    end
  end

  %i[failed cancelled blocked].each do |terminal_status|
    context "with a saved #{terminal_status} Target" do
      let(:status) { terminal_status }

      it "finalizes routing once without changing Agent results or retention" do
        result = saved.to_result
        holds = agents.keys.to_h { |id| [id, persistence.retained_references(agent_id: id)] }
        expect(finalize.to_result).to eq(result)
        expect(current_route).to have_attributes(phase: "stable", handoff_revision: 2)
        expect(persistence.observe_execution(agent_id: target.agent_id, execution_id: "target-run").to_result).to eq(result)
        expect(agents.keys.to_h { |id| [id, persistence.retained_references(agent_id: id)] }).to eq(holds)
        expect(finalize(described_class.new(persistence: stores.multi_agent, main_agent_id: main.agent_id, agents: agents))).to eq(saved)
        expect(current_route.handoff_revision).to eq(2)
      end
    end
  end

  it "observes both exact custodians outside all persistence transactions" do
    depth = 0
    allow(stores.multi_agent).to receive(:transaction).and_wrap_original do |original, &body|
      depth += 1
      original.call(&body)
    ensure
      depth -= 1
    end
    [source, target].each do |agent|
      expect(agent).to receive(:__execution_custody_pending?).with("#{agent.equal?(source) ? "source" : "target"}-run") do
        expect(depth).to eq(0)
        false
      end
    end
    finalize
  end

  it "guards the routing before the full ordered Agent set including a non-main Source" do
    order = []
    allow_any_instance_of(Phronomy::MultiAgent::Persistence::HandoffStateRepository).to receive(:load_locked).and_wrap_original do |original, id|
      order << :route
      original.call(id)
    end
    allow(persistence).to receive(:guard_agents).and_wrap_original do |original, scope, agent_ids:|
      expect(order.last).to eq(:route)
      expect(agent_ids).to eq([source.agent_id, main.agent_id, target.agent_id])
      order << :agents
      original.call(scope, agent_ids: agent_ids)
    end
    finalize
  end

  it "rejects a candidate nested transaction before observing custody or writing" do
    expect(source).not_to receive(:__execution_custody_pending?)
    expect(operation).not_to receive(:save_routing)
    expect {
      stores.multi_agent.transaction { finalize }
    }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
      expect(error.disposition).to eq(:not_attempted)
      expect(error.finalization_error).to be_a(Phronomy::Persistence::TransactionError)
      expect(error.execution_result).to eq(saved.to_result)
    }
    expect(current_route.to_h).to eq(routing.to_h)
  end

  it "does not apply the initial pending transition to an unsupported active route" do
    change_route(phase: "target_active")
    expect(source).not_to receive(:__execution_custody_pending?)
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError, /pending Target transition/)
    expect(current_route.phase).to eq("target_active")
  end

  ["Source", "Target"].each do |role|
    it "refuses a terminal fact while the #{role} retains local custody" do
      allow((role == "Source") ? source : target).to receive(:__execution_custody_pending?).and_return(true)
      expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
        expect(error.disposition).to eq(:not_attempted)
        expect(error.execution_id).to eq("chain-entry")
        expect(error.target_execution_id).to eq("target-run")
        expect(error.execution_result).to eq(saved.to_result)
        expect(error.execution_error.message).to eq("ArgumentError: intake rejected")
      }
      expect(current_route.to_h).to eq(routing.to_h)
    end
  end

  it "rejects missing exact Source retention" do
    persistence.transaction { |_records, scope| persistence.release_retention(agent_id: source.agent_id, owner_key: owner_key, scope: scope) }
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError, /retention/)
    expect(current_route.phase).to eq("target_pending")
  end

  it "rejects missing exact Target retention" do
    persistence.transaction { |_records, scope| persistence.release_retention(agent_id: target.agent_id, owner_key: owner_key, scope: scope) }
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError, /retention/)
    expect(current_route.phase).to eq("target_pending")
  end

  it "rejects a route whose context no longer matches the saved Source receipt" do
    change_route(active_handoff_context_ref: "another-context")
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError, /transfer identity/)
    expect(current_route.phase).to eq("target_pending")
  end

  it "reports unavailable exact Source custody without reconstructing a graph Agent" do
    missing_source = described_class.new(persistence: stores.multi_agent, main_agent_id: main.agent_id,
      agents: agents.except(source.agent_id))
    expect { finalize(missing_source) }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError, /graph lacks/)
    expect(current_route.phase).to eq("target_pending")
  end

  it "rejects changed authority after the local custody observation" do
    allow(target).to receive(:__execution_custody_pending?) do
      change_route(metadata: routing.metadata.merge("changed" => true))
      false
    end
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError, /authority changed/)
    expect(current_route.phase).to eq("target_pending")
  end

  it "ignores another domain's retention changes after custody observation" do
    allow(target).to receive(:__execution_custody_pending?) do
      persistence.retain(Phronomy::Agent::Retention.new(agent_id: target.agent_id,
        owner_key: "another-domain", execution_id: "target-run"))
      false
    end
    finalize
    expect(current_route.phase).to eq("stable")
    expect(persistence.retained_references(agent_id: target.agent_id).map(&:owner_key)).to include("another-domain", owner_key)
  end

  it "adopts the exact concurrent finalization without a second write" do
    allow(target).to receive(:__execution_custody_pending?) do
      change_route(phase: "stable")
      false
    end
    expect(operation).not_to receive(:save_routing)
    finalize
    expect(current_route.handoff_revision).to eq(2)
  end

  it "reports confirmed pre-state and permits a later explicit routing-only attempt" do
    allow(operation).to receive(:save_routing).and_raise(IOError, "write refused")
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
      expect(error.disposition).to eq(:not_committed)
      expect(error.finalization_error.message).to eq("write refused")
      expect(error.read_error).to be_nil
    }
    expect(current_route.phase).to eq("target_pending")
    finalize(described_class.new(persistence: stores.multi_agent, main_agent_id: main.agent_id, agents: agents))
    expect(current_route.phase).to eq("stable")
  end

  it "does not reconcile a stale intended write if a reused sequential helper loses fresh authority" do
    allow(operation).to receive(:save_routing).and_raise(IOError, "first save refused")
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
      expect(error.disposition).to eq(:not_committed)
    }
    allow(target).to receive(:__execution_custody_pending?) do
      change_route(metadata: routing.metadata.merge("changed" => true))
      false
    end
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
      expect(error.disposition).to eq(:not_attempted)
      expect(error.finalization_error.message).to include("authority changed")
    }
  end

  def lose_save_reply(unreadable: false, &after_save)
    wrote = false
    fault = true
    allow(operation).to receive(:save_routing).and_wrap_original do |original, *arguments|
      wrote = true
      original.call(*arguments)
    end
    allow(stores.multi_agent).to receive(:transaction).and_wrap_original do |original, &body|
      raise IOError, "proof unavailable" if unreadable && !fault
      result = original.call(&body)
      if wrote && fault
        fault = false
        after_save&.call
        raise IOError, "save reply lost"
      end
      result
    end
  end

  it "adopts confirmed post-state after response loss" do
    lose_save_reply
    expect(finalize).to eq(saved)
    expect(current_route).to have_attributes(phase: "stable", handoff_revision: 2)
  end

  it "confirms its committed save when another domain adds retention before readback" do
    lose_save_reply do
      persistence.retain(Phronomy::Agent::Retention.new(agent_id: source.agent_id,
        owner_key: "another-domain", execution_id: "source-run"))
    end
    expect(finalize).to eq(saved)
    expect(current_route).to have_attributes(phase: "stable", handoff_revision: 2)
  end

  it "keeps the saved business failure and unreadable routing confirmation distinct" do
    lose_save_reply(unreadable: true)
    expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
      expect(error.disposition).to eq(:unknown)
      expect(error.execution_result).to eq(saved.to_result)
      expect(error.finalization_error.message).to eq("save reply lost")
      expect(error.read_error.message).to eq("proof unavailable")
    }
  end

  it "leaves historical terminal chains unrelated to the current pending Target unchanged" do
    change_route(pending_target_execution_id: "new-target")
    expect(source).not_to receive(:__execution_custody_pending?)
    expect(finalize).to eq(saved)
    expect(current_route.pending_target_execution_id).to eq("new-target")
  end

  it "does not treat success, transfer, approval, or unfinished status as this failure correction" do
    %i[completed handed_off suspended preparing active absent].each do |status|
      value = saved.with(status: status)
      expect(operation.call(execution_id: "chain-entry", target: value)).to eq(value)
    end
    expect(current_route.to_h).to eq(routing.to_h)
  end

  context "with an Agent-specific saved diagnostic" do
    let(:failure) do
      Phronomy::Agent::OutputError.new(execution_id: "target-run", schema_digest: "saved-schema",
        reason: "schema_mismatch", violations: [], raw_output: "{} ").diagnostic
    end

    it "uses the Agent public observation's restored error variant" do
      allow(target).to receive(:__execution_custody_pending?).and_return(true)
      expect { finalize }.to raise_error(Phronomy::MultiAgent::HandoffFinalizationError) { |error|
        expect(error.execution_error).to be_a(Phronomy::Agent::OutputError)
        expect(error.execution_error.schema_digest).to eq("saved-schema")
        expect(error.execution_result[:error]).to eq(failure)
      }
    end
  end
end
