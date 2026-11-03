# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/hosted_subagent"

RSpec.describe "Releasing a completed native pair", :integration do
  include_context "a native child requiring approval"

  def complete_pair(target = parent, id = root_id)
    _, request, child = start(target, id)
    child.approve(request.execution_id, approval_request_id: request.id)
    expect(target.resume(id)).to include(output: "parent completed")
    [request.execution_id, child]
  end

  def saved_history(child, id, child_id)
    extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: id,
      binding_key: Phronomy::MultiAgent::DurableSubagentCoordinator::BINDING_KEY)
    {extension: extension, slots: stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children"),
     executions: [id, child_id].map { |execution_id| stores.agent.executions.load(execution_id).to_h },
     holds: [parent, child].map { |agent| stores.agent.retained_references(agent_id: agent.agent_id) }}
  end

  it "releases both incarnations without discarding their imported slot, transcripts or purge protection" do
    recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed", "next turn"])
    child_id, child = complete_pair
    before = saved_history(child, root_id, child_id)
    expect(before.fetch(:slots)).to match([a_hash_including("execution_id" => child_id, "imported" => true)])
    transcripts = [parent, child].map { |agent| agent.transcript.map(&:to_h) }
    [parent, child].each do |agent|
      expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    end

    expect(parent.unload_with_completed_child!(root_id, execution_id: child_id)).to be(true)
    [parent, child].each do |agent|
      expect(agent.class.get(agent.agent_id)).to be_nil
      expect { agent.transcript }.to raise_error(Phronomy::AgentUnloadedError)
    end
    expect(saved_history(child, root_id, child_id)).to eq(before)

    loaded_parent = parent_class.load(parent.agent_id, **options)
    loaded_child = child_class.load(child.agent_id, persistence: stores.agent)
    expect(parent.unload_with_completed_child!(root_id, execution_id: child_id)).to be(false)
    expect([loaded_parent, loaded_child].map { |agent| agent.transcript.map(&:to_h) }).to eq(transcripts)
    expect(loaded_parent.resume(root_id)).to include(output: "parent completed")
    expect(loaded_child.resume(child_id)).to include(output: "child completed")
    [loaded_parent, loaded_child].each do |agent|
      expect { agent.purge! }.to raise_error(Phronomy::AgentBusyError)
      expect_live(agent)
    end
    expect(saved_history(child, root_id, child_id)).to eq(before)
    expect(recorder.calls.size).to eq(4)
    expect(loaded_parent.invoke("follow up")).to include(output: "next turn")
    expect(recorder.last_messages.select { |item| item["role"] == "user" }.map { |item| item["content"] }).to eq(["run", "follow up"])

    expect(stores.multi_agent.forget_subagents(agent_id: parent.agent_id, execution_id: root_id)).to be(true)
    expect(loaded_child.unload!).to be(true)
    expect(loaded_parent.unload!).to be(true)
  end

  it "can release a reloaded parent without reloading the child or touching either execution" do
    recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    id, child = complete_pair
    history = saved_history(child, root_id, id)
    parent.unload_with_completed_child!(root_id, execution_id: id)
    loaded = parent_class.load(parent.agent_id, **options)
    expect(child_class).not_to receive(:load)
    expect(loaded.unload_with_completed_child!(root_id, execution_id: id)).to be(true)
    expect(parent_class.get(parent.agent_id)).to be_nil
    expect(child_class.get(child.agent_id)).to be_nil
    expect(saved_history(child, root_id, id)).to eq(history)
    expect(recorder.calls.size).to eq(4)
  end

  it "requires the parent's terminal commit even after the child reaches its terminal state" do
    LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    _, request, child = start
    id = request.execution_id
    expect { parent.unload_with_completed_child!(root_id, execution_id: id) }.to raise_error(Phronomy::AgentBusyError)
    child.approve(id, approval_request_id: request.id)
    expect(stores.agent.observe_execution(agent_id: child.agent_id, execution_id: id)).to be_terminal
    expect { parent.unload_with_completed_child!(root_id, execution_id: id) }.to raise_error(Phronomy::AgentBusyError)
    expect_live(parent)
    expect_live(child)
    parent.resume(root_id)
    expect(parent.unload_with_completed_child!(root_id, execution_id: id)).to be(true)
  end

  it "does not release a pair under an accepted operation or an additional durable holder on either Agent" do
    LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    id, child = complete_pair
    [parent, child].each do |busy|
      lease = busy.send(:__acquire_operation!)
      begin
        expect { parent.unload_with_completed_child!(root_id, execution_id: id) }.to raise_error(Phronomy::AgentBusyError)
        expect_live(parent)
        expect_live(child)
      ensure
        lease.release
      end
      foreign = Phronomy::Agent::Retention.new(agent_id: busy.agent_id, owner_key: "opaque:consumer")
      stores.agent.retain(foreign)
      expect { parent.unload_with_completed_child!(root_id, execution_id: id) }.to raise_error(Phronomy::AgentBusyError)
      expect_live(parent)
      expect_live(child)
      expect(stores.agent.retained_references(agent_id: busy.agent_id)).to include(foreign)
      stores.agent.coordinator.atomic do |scope|
        stores.agent.release_retention(agent_id: busy.agent_id, owner_key: foreign.owner_key, scope: scope)
      end
    end
    expect(parent.unload_with_completed_child!(root_id, execution_id: id)).to be(true)
  end

  it "does not unload based on the uncommitted removal of another owner's retention" do
    LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    id, child = complete_pair
    foreign = Phronomy::Agent::Retention.new(agent_id: child.agent_id, owner_key: "other-consumer")
    stores.agent.retain(foreign)
    expect do
      stores.agent.coordinator.atomic do |scope|
        stores.agent.release_retention(agent_id: child.agent_id, owner_key: foreign.owner_key, scope: scope)
        parent.unload_with_completed_child!(root_id, execution_id: id)
      end
    end.to raise_error(Phronomy::Persistence::TransactionError)
    expect(stores.agent.retained_references(agent_id: child.agent_id)).to include(foreign)
    expect_live(parent)
    expect_live(child)
  end

  [true, false].each do |child_present|
    it "preserves the #{child_present ? "resident" : "absent"} child across a failing release while excluding concurrent loads" do
      LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
      id, child = complete_pair
      target = parent
      unless child_present
        parent.unload_with_completed_child!(root_id, execution_id: id)
        target = parent_class.load(parent.agent_id, **options)
      end
      before = saved_history(child, root_id, id)
      entered, proceed = Queue.new, Queue.new
      allow_any_instance_of(Phronomy::MultiAgent::DurableSubagentCoordinator).to receive(:completed_child_pair?) do
        entered << true
        Timeout.timeout(8) { proceed.pop }
        raise Phronomy::Persistence::TransactionError, "terminal read failed"
      end
      release = Thread.new do
        target.unload_with_completed_child!(root_id, execution_id: id)
      rescue Phronomy::Persistence::TransactionError => error
        error
      end

      Timeout.timeout(8) { entered.pop }
      expect { parent_class.load(target.agent_id, **options) }.to raise_error(Phronomy::AgentBusyError)
      expect { child_class.load(child.agent_id, persistence: stores.agent) }.to raise_error(Phronomy::AgentBusyError)
      proceed << true
      expect(Timeout.timeout(8) { release.value }).to be_a(Phronomy::Persistence::TransactionError)
      expect_live(target)
      expect(child_class.get(child.agent_id)).to equal(child_present ? child : nil)
      expect(saved_history(child, root_id, id)).to eq(before)
    ensure
      proceed&.push(true)
      release&.join(8)
    end
  end

  it "separates completed history from a newer active dispatch on the same parent" do
    LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"] * 2)
    first_id, first_child = complete_pair
    first_history = saved_history(first_child, root_id, first_id)
    second_root = SecureRandom.uuid
    _, second, second_child = start(parent, second_root)
    expect { parent.unload_with_completed_child!(root_id, execution_id: first_id) }.to raise_error(Phronomy::AgentBusyError)
    expect_live(parent)
    expect_live(first_child)
    expect_live(second_child)
    second_child.approve(second.execution_id, approval_request_id: second.id)
    parent.resume(second_root)
    expect { parent.unload_with_completed_child!(second_root, execution_id: first_id) }.to raise_error(Phronomy::AgentBusyError)
    expect(parent.unload_with_completed_child!(second_root, execution_id: second.execution_id)).to be(true)
    expect_live(first_child)
    expect(saved_history(first_child, root_id, first_id).except(:holds)).to eq(first_history.except(:holds))
    loaded = parent_class.load(parent.agent_id, **options)
    expect(loaded.unload_with_completed_child!(root_id, execution_id: first_id)).to be(true)
  end
end
