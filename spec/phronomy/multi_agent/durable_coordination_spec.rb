# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Durable semantic coordination (F1/F4; external X0 remains Agent Recovery)" do
  include_context "durable coordination runtime"

  it "discovers retained outcomes without loading owners or delivering callbacks (RC-01)" do
    llm = LLMStub.activate(responses: ["first", "second"])
    agent = worker.create(agent_id: "read-only-owner", persistence: store)
    ids = 2.times.map { |i| agent.invoke("input-#{i}").fetch(:execution_id) }.sort
    restored = reboot(store.snapshot)
    expect(worker.get(agent.agent_id)).to be_nil
    page = restored.list_executions(agent.agent_id, limit: 1)
    expect(page.map(&:execution_id)).to eq(ids.first(1))
    expect(restored.list_executions(agent.agent_id, after: ids.first).map(&:execution_id)).to eq(ids.last(1))
    expect(restored.execution_result(ids.first)[:status]).to eq(:completed)
    expect(worker.get(agent.agent_id)).to be_nil
    expect(llm.calls.size).to eq(2)
  end

  it "does not reinterpret a read failure as absent execution (RC-02)" do
    agent = worker.create(persistence: store)
    allow(store.executions).to receive(:load).with("reserved").and_raise(IOError, "read unavailable")
    expect(agent).not_to receive(:_start_agent_operation)
    expect do
      Phronomy::Agent::ExactExecution.start(agent: agent, execution_id: "reserved", input: "work").wait_result(timeout: 2)
    end.to raise_error(IOError, /read unavailable/)
  end

  it "adopts Team admission, operation, assignment and terminal commits after F1 response loss" do
    team = team_class.create(team_id: "f1-team", persistence: store)
    versions = {}
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      if run && !versions[run.execution_revision]
        versions[run.execution_revision] = true
        raise IOError, "committed response lost"
      end
    end
    llm = LLMStub.activate(responses: team_responses)
    result = team.invoke("plan")
    expect(result.first.fetch("result")).to eq("worker-result")
    expect(team.executions.size).to eq(1)
    expect(team.executions.first.tasks.size).to eq(1)
    expect(versions.size).to be >= 6
    expect(llm.calls.size).to eq(4)
  end

  it "reuses a worker terminal result lost before Team assignment settlement (RC-02/03)" do
    team = team_class.create(team_id: "worker-crash", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      assignment = run&.assignments&.first
      if !captured && assignment && assignment["state"] == "reserved"
        begin
          child = backend.executions.load(assignment.fetch("execution_id"))
          captured = backend.snapshot if child.terminal?
        rescue Phronomy::Persistence::NotFoundError
          nil
        end
      end
    end
    LLMStub.activate(responses: team_responses)
    expected = team.invoke("plan")
    expect(captured).not_to be_nil
    restored = reboot(captured)
    llm = LLMStub.activate(responses: ["unexpected replay"])
    loaded = team_class.load(team.team_id, persistence: restored)
    id = loaded.executions.first.team_execution_id
    expect(loaded.resume(id)).to eq(expected)
    expect(llm.calls).to be_empty
  end

  it "commits an authorized task batch in Provider order even when finalize runs first" do
    team = team_class.create(team_id: "ordered-batch", persistence: store)
    original = team.method(:apply_operation)
    allow(team).to receive(:apply_operation) do |id, key, operation, args|
      if operation == :enqueue_task
        run = team.executions.first
        coordinator = store.executions.load(run.coordinator.fetch("execution_id"))
        finalize = coordinator.metadata.fetch(Phronomy::Agent::RecoverySupport::TOOL_BATCH_METADATA_KEY).last
        original.call(id, finalize.fetch("tool_invocation_id"), :finalize, {})
      end
      original.call(id, key, operation, args)
    end
    calls = [["enqueue_task", {description: "one"}], ["enqueue_task", {description: "two"}], ["finalize", {}]].each_with_index.map do |(name, args), i|
      {"id" => "batch-#{i}", "type" => "function", "function" => {"name" => name, "arguments" => JSON.generate(args)}}
    end
    batch = {"id" => "ordered-batch", "object" => "chat.completion", "model" => "stub-model",
             "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil, "tool_calls" => calls}, "finish_reason" => "tool_calls"}]}
    llm = LLMStub.activate(responses: [batch, "queued", "first-result", "second-result"])
    expect(team.invoke("plan").map { |a| a.fetch("task").fetch("description") }).to eq(%w[one two])
    operations = team.executions.first.metadata.fetch("operations").values
    expect(operations.size).to eq(3)
    expect(operations.find { |entry| entry.fetch("operation") == "finalize" }.fetch("result")).to include("2 task(s)")
    expect(llm.calls.size).to eq(4)
  end

  it "returns an F1 readback failure without dispatching admitted Team work (RC-02-C)" do
    team = team_class.create(team_id: "readback-unavailable", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      captured = backend.snapshot
      allow(backend.team_executions).to receive(:load).and_raise(IOError, "readback unavailable")
      raise IOError, "admission response lost"
    end
    llm = LLMStub.activate(responses: ["must not start"])
    expect { team.invoke("plan") }.to raise_error(IOError, "readback unavailable")
    expect(llm.calls).to be_empty
    restored = reboot(captured)
    runs = restored.list_team_executions(team.team_id)
    expect(runs.size).to eq(1)
    expect(runs.first.status).to eq("active")
  end

  it "reconciles a committed finalize operation without asking Application for facts" do
    team = team_class.create(team_id: "operation-crash", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      captured = backend.snapshot if !captured && run&.metadata&.fetch("finalized", false) && run.phase == "coordinator"
    end
    LLMStub.activate(responses: team_responses)
    team.invoke("plan")
    restored = reboot(captured)
    events = []
    loaded = team_class.load(team.team_id, persistence: restored, on_event: ->(event) { events << event.type })
    llm = LLMStub.activate(responses: ["queued after restart", "worker-result"])
    id = loaded.executions.first.team_execution_id
    expect(loaded.resume(id).first.fetch("result")).to eq("worker-result")
    run = loaded.executions.first
    expect(run.tasks.size).to eq(1)
    expect(run.metadata.fetch("operations").size).to eq(2)
    expect(events).not_to include(:recovery_resolution_required)
    expect(llm.calls.size).to eq(2)
  end

  it "keeps Team active when a hidden coordinator requires external Provider resolution" do
    team = team_class.create(team_id: "external-crash", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      next unless run && !captured
      begin
        child = backend.executions.load(run.coordinator.fetch("execution_id"))
        captured = backend.snapshot if child.phase == :calling_llm
      rescue Phronomy::Persistence::NotFoundError
        nil
      end
    end
    LLMStub.activate(responses: team_responses)
    team.invoke("plan")
    restored = reboot(captured)
    loaded = team_class.load(team.team_id, persistence: restored)
    id = loaded.executions.first.team_execution_id
    llm = LLMStub.activate(responses: ["must not replay"])
    expect { loaded.resume(id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(loaded.executions.first.status).to eq("active")
    loaded.cancel(id)
    expect { loaded.resume(id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    cancelled_snapshot = reboot(restored.snapshot)
    loaded = team_class.load(team.team_id, persistence: cancelled_snapshot)
    expect { loaded.resume(id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(loaded.executions.first.status).to eq("active")
    expect(loaded.executions.first.metadata["cancel_requested"]).to be(true)
    expect(cancelled_snapshot.executions.load(loaded.executions.first.coordinator.fetch("execution_id")).terminal?).to be(false)
    expect(llm.calls).to be_empty
  end

  it "stops a reserved worker on explicit Team cancellation and retains its ID (RC-04)" do
    team = team_class.create(team_id: "cancel-crash", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_team_executions(team.team_id).first
      captured = backend.snapshot if !captured && run && !run.assignments.empty?
    end
    LLMStub.activate(responses: team_responses)
    team.invoke("plan")
    restored = reboot(captured)
    loaded = team_class.load(team.team_id, persistence: restored)
    run = loaded.executions.first
    reserved = run.assignments.first.fetch("execution_id")
    loaded.cancel(run.team_execution_id)
    # The request itself also survives F4 before any child reconciliation.
    restored = reboot(restored.snapshot)
    loaded = team_class.load(team.team_id, persistence: restored)
    llm = LLMStub.activate(responses: ["must not start"])
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /cancelled/)
    expect(loaded.executions.first.status).to eq("cancelled")
    expect(loaded.executions.first.assignments.first.fetch("execution_id")).to eq(reserved)
    expect { restored.executions.load(reserved) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(llm.calls).to be_empty
  end

  it "rejects a changed worker definition before continuation (RC-03)" do
    team = team_class.create(team_id: "version-crash", persistence: store)
    run = team.send(:admit, "plan")
    restored = reboot(store.snapshot)
    worker.agent_definition id: "durable-worker", version: 2
    loaded = team_class.load(team.team_id, persistence: restored)
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::ConfigurationError, /definition mismatch/)
  end

  it "reuses a static child committed before its parent resumed" do
    parent = parent_class.create(agent_id: "parent-crash", persistence: store)
    parent.add_knowledge("saved knowledge", metadata: {"source" => "fixture"})
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_executions(parent.agent_id).first
      next unless !captured && run&.active? && run.metadata["multi_agent_coordination_ref"]
      slots = backend.contents.fetch_json(run.metadata.fetch("multi_agent_coordination_ref")).fetch("children")
      slot = slots.first
      begin
        child = backend.executions.load(slot.fetch("execution_id"))
        captured = backend.snapshot if child.terminal? && run.phase == :dispatching_tools
      rescue Phronomy::Persistence::NotFoundError
        nil
      end
    end
    LLMStub.activate(responses: [LLMStub.tool_call_response("dispatch_to_worker", {input: "job"}), "child-result", "parent-result"])
    parent.invoke("plan")
    expect(captured).not_to be_nil
    restored = reboot(captured)
    llm = LLMStub.activate(responses: ["parent-after-restart"])
    loaded = parent_class.load(parent.agent_id, persistence: restored)
    id = restored.list_executions(parent.agent_id).first.execution_id
    expect(loaded.resume(id)[:output]).to eq("parent-after-restart")
    expect(llm.calls.size).to eq(1)
    slots = restored.contents.fetch_json(restored.executions.load(id).metadata.fetch("multi_agent_coordination_ref")).fetch("children")
    expect(slots.first.fetch("state")).to eq("completed")
    knowledge = restored.journals.read(slots.first.fetch("agent_id")).find { |record| record.kind == :knowledge }
    expect(knowledge.metadata).to include("source" => "fixture")
  end

  it "keeps standalone fan-out Runtime-only without admitting an Orchestrator execution" do
    parent = parent_class.create(persistence: store)
    LLMStub.activate(responses: ["worker-result"])
    expect(parent.fan_out(agent: worker, inputs: ["one"]).size).to eq(1)
    expect(store.list_executions(parent.agent_id)).to be_empty
  end

  it "persists an aggregator error and does not recompute a terminal Team result" do
    aggregate_calls = 0
    team_class.aggregate { |_values|
      aggregate_calls += 1
      raise "aggregate failed"
    }
    team = team_class.create(persistence: store)
    LLMStub.activate(responses: team_responses)
    expect { team.invoke("plan") }.to raise_error(Phronomy::Error, /aggregate failed/)
    run = team.executions.first
    expect(run.status).to eq("failed")
    expect(team.result(run.team_execution_id)[:error].fetch("message")).to eq("aggregate failed")
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::Error, /aggregate failed/)
    expect(aggregate_calls).to eq(1)
  end

  it "retains parent cancellation while an active child needs external factual resolution" do
    parent = parent_class.create(agent_id: "cancel-parent", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_executions(parent.agent_id).first
      next unless !captured && run&.metadata&.fetch("multi_agent_coordination_ref", nil)
      child_id = backend.contents.fetch_json(run.metadata.fetch("multi_agent_coordination_ref")).fetch("children").first.fetch("execution_id")
      begin
        captured = backend.snapshot if backend.executions.load(child_id).phase == :calling_llm
      rescue Phronomy::Persistence::NotFoundError
        nil
      end
    end
    LLMStub.activate(responses: [LLMStub.tool_call_response("dispatch_to_worker", {input: "job"}), "child", "parent"])
    parent.invoke("plan")
    restored = reboot(captured)
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    llm = LLMStub.activate(responses: ["must not replay"])
    loaded = parent_class.load(parent.agent_id, persistence: restored)
    id = restored.list_executions(parent.agent_id).first.execution_id
    expect { loaded.resume(id, config: {cancellation_token: token}) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    run = restored.executions.load(id)
    expect(run).to be_active
    expect(run.metadata["coordination_cancel_requested"]).to be(true)
    snapshot = reboot(restored.snapshot)
    loaded = parent_class.load(parent.agent_id, persistence: snapshot)
    expect { loaded.resume(id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(snapshot.executions.load(id).metadata["coordination_cancel_requested"]).to be(true)
    expect(llm.calls).to be_empty
  end

  it "recovers the saved Handoff Context and exact Target with current compatible graph wiring" do
    source = worker.create(agent_id: "context-source", persistence: store)
    target = worker.create(agent_id: "context-target", persistence: store)
    edge = Phronomy::Agent::Handoff.new(source_agent: source, target_agent: target)
    name = Phronomy::Agent::HandoffCapabilityFactory.build(edge).tool_name
    captured = nil
    store.after_commit = proc do |backend|
      routing = backend.handoff_states.load(source.agent_id)
      captured = backend.snapshot if !captured && routing&.phase == "target_pending"
    end
    LLMStub.activate(responses: [LLMStub.tool_call_response(name, {responsibility: "saved responsibility"}), "target"])
    Phronomy::Agent::HandoffRunner.new(main_agent: source, handoffs: [edge]).invoke("original request")
    restored = reboot(captured)
    source_id = restored.list_executions(source.agent_id).first.execution_id
    expect(restored.handoff_result(source_id)).to include(agent_id: target.agent_id, status: :active, reserved: true)
    expect(worker.get(source.agent_id)).to be_nil
    expect(worker.get(target.agent_id)).to be_nil
    source = worker.load(source.agent_id, persistence: restored)
    target = worker.load(target.agent_id, persistence: restored)
    source_id = restored.list_executions(source.agent_id).first.execution_id
    no_graph = Phronomy::Agent::HandoffRunner.new(main_agent: source)
    reserved = no_graph.result(source_id)
    expect(reserved).to include(agent_id: target.agent_id, status: :active, reserved: true)
    expect { source.purge! }.to raise_error(Phronomy::AgentBusyError, /unfinished turn/)
    expect { no_graph.invoke("must not replace input") }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    policy = Phronomy::Agent::HandoffPolicy.define do
      forbidden :current_request
      forbidden :history
      forbidden :knowledge
      forbidden :tool_exchanges
    end
    changed = Phronomy::Agent::Handoff.new(source_agent: source, target_agent: target, policy: policy)
    allow_any_instance_of(Phronomy::Agent::HandoffProjection).to receive(:build_terminal).and_raise("must not reproject")
    llm = LLMStub.activate(responses: ["after restart"])
    runner = Phronomy::Agent::HandoffRunner.new(main_agent: source, handoffs: [changed])
    result = runner.invoke("ignored new input")
    expect(result[:execution_id]).to eq(reserved[:execution_id])
    expect(llm.calls.size).to eq(1)
    expect(JSON.generate(llm.last_messages)).to include("original request", "saved responsibility")
    target.purge!
    expect { restored.handoff_result(source_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    source.purge!
    expect(restored.handoff_states.load(source.agent_id)).to be_nil
  end

  it "cancels a transferred absent Target without starting it or rewinding responsibility" do
    source = worker.create(agent_id: "cancel-source", persistence: store)
    target = worker.create(agent_id: "cancel-target", persistence: store)
    edge = Phronomy::Agent::Handoff.new(source_agent: source, target_agent: target)
    name = Phronomy::Agent::HandoffCapabilityFactory.build(edge).tool_name
    captured = nil
    store.after_commit = proc do |backend|
      captured = backend.snapshot if !captured && backend.handoff_states.load(source.agent_id)&.phase == "target_pending"
    end
    LLMStub.activate(responses: [LLMStub.tool_call_response(name, {responsibility: "continue"}), "target"])
    Phronomy::Agent::HandoffRunner.new(main_agent: source, handoffs: [edge]).invoke("plan")
    restored = reboot(captured)
    source_id = restored.list_executions(source.agent_id).first.execution_id
    source = worker.load(source.agent_id, persistence: restored)
    runner = Phronomy::Agent::HandoffRunner.new(main_agent: source)
    reserved_id = runner.result(source_id).fetch(:execution_id)
    runner.cancel(source_id)
    restored = reboot(restored.snapshot)
    source = worker.load(source.agent_id, persistence: restored)
    target = worker.load(target.agent_id, persistence: restored)
    edge = Phronomy::Agent::Handoff.new(source_agent: source, target_agent: target)
    runner = Phronomy::Agent::HandoffRunner.new(main_agent: source, handoffs: [edge])
    expect(runner.result(source_id)).to include(execution_id: reserved_id, status: :cancelled)
    expect(restored.executions.load(source_id).status).to eq(:handed_off)
    expect { restored.executions.load(reserved_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(restored.handoff_states.load(source.agent_id).active_agent_id).to eq(target.agent_id)
    llm = LLMStub.activate(responses: ["next turn"])
    expect(runner.invoke("new request")[:output]).to eq("next turn")
    expect(llm.calls.size).to eq(1)
    expect(runner.result(source_id)[:status]).to eq(:cancelled)
  end

  it "adopts the atomic Source transfer after F1 without replaying Source" do
    source = worker.create(agent_id: "handoff-source", persistence: store)
    target = worker.create(agent_id: "handoff-target", persistence: store)
    edge = Phronomy::Agent::Handoff.new(source_agent: source, target_agent: target)
    name = Phronomy::Agent::HandoffCapabilityFactory.build(edge).tool_name
    fired = false
    store.after_commit = proc do |backend|
      routing = backend.handoff_states.load(source.agent_id)
      if !fired && routing && routing.phase == "target_pending"
        fired = true
        raise IOError, "Source transfer response lost"
      end
    end
    llm = LLMStub.activate(responses: [LLMStub.tool_call_response(name, {responsibility: "continue"}), "target-result"])
    runner = Phronomy::Agent::HandoffRunner.new(main_agent: source, handoffs: [edge])
    expect(runner.invoke("plan")[:output]).to eq("target-result")
    expect(fired).to be(true)
    expect(llm.calls.size).to eq(2)
    source_id = store.list_executions(source.agent_id).first.execution_id
    expect(runner.result(source_id)[:result]).to eq("target-result")
    expect(store.handoff_states.load(source.agent_id).phase).to eq("stable")
  end

  it "recovers a mixed external/owned Tool batch by resolving only the external fact" do
    effects = 0
    external = Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "external_effect"
      description "Record an Application side effect."
      define_method(:execute) {
        effects += 1
        "effect-result"
      }
    end
    parent_class.tools(parent_class.tools.to_h { |tool| [tool, nil] }.merge(external => nil))
    parent = parent_class.create(agent_id: "mixed-parent", persistence: store)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.list_executions(parent.agent_id).first
      next unless !captured && run&.phase == :dispatching_tools && run.metadata["multi_agent_coordination_ref"]
      child = backend.contents.fetch_json(run.metadata.fetch("multi_agent_coordination_ref")).fetch("children").first
      begin
        captured = backend.snapshot if backend.executions.load(child.fetch("execution_id")).terminal?
      rescue Phronomy::Persistence::NotFoundError
        nil
      end
    end
    calls = [["external_effect", {}], ["dispatch_to_worker", {input: "job"}]].each_with_index.map do |(name, args), i|
      {"id" => "mixed-#{i}", "type" => "function", "function" => {"name" => name, "arguments" => JSON.generate(args)}}
    end
    response = {"id" => "mixed-batch", "object" => "chat.completion", "model" => "stub-model",
                "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil, "tool_calls" => calls}, "finish_reason" => "tool_calls"}]}
    LLMStub.activate(responses: [response, "child", "parent"])
    parent.invoke("plan")
    expect(captured).not_to be_nil
    expect(effects).to eq(1)
    restored = reboot(captured)
    events = Queue.new
    llm = LLMStub.activate(responses: ["parent resumed"])
    loaded = parent_class.load(parent.agent_id, persistence: restored, on_event: ->(event) { events << event if event.type == :recovery_resolution_required })
    event = Timeout.timeout(2) { events.pop }
    payload = event.payload
    run = restored.executions.load(payload.fetch(:execution_id))
    external_entry = run.metadata.fetch(Phronomy::Agent::RecoverySupport::TOOL_BATCH_METADATA_KEY).find { |entry| entry.fetch("tool_name") == "external_effect" }
    expect(payload.fetch(:subject).fetch(:tool_invocation_id)).to eq(external_entry.fetch("tool_invocation_id"))
    resolution = loaded.resolve_async(payload.fetch(:execution_id),
      expected_execution_revision: payload.fetch(:execution_revision), subject: payload.fetch(:subject),
      outcome: :succeeded, result: "effect-result")
    expect(resolution.wait_result(timeout: 3)[:output]).to eq("parent resumed")
    expect(effects).to eq(1)
    expect(llm.calls.size).to eq(1)
    expect(events).to be_empty
    tool_results = llm.last_messages.select { |message| message.fetch("role") == "tool" }
    expect(tool_results.map { |message| message.fetch("tool_call_id") }).to contain_exactly("mixed-0", "mixed-1")
  end
end
