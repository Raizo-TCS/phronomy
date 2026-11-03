# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/hosted_subagent"

RSpec.describe "Hosted Orchestrator with a child awaiting approval", :integration do
  include_context "a native child requiring approval"

  it "releases both local owners, preserves their saved executions and restores the original child request" do
    recorder = LLMStub.activate(responses: [dispatch, protected_call, "child completed", "parent completed"])
    handle, request, child = start
    saved = saved_state(request.execution_id)

    wait = detach(handle, request)
    expect(wait.execution_revision).to eq(stores.agent.executions.load(request.execution_id).execution_revision)
    expect(wait.execution_id).to eq(request.execution_id)
    expect(wait.approval_request_id).to eq(request.id)
    expect(stores.agent.standalone_approval_wait(agent_id: child.agent_id, execution_id: request.execution_id)).to be_nil
    [parent, child].each do |original|
      expect(original.class.get(original.agent_id)).to be_nil
      expect { original.transcript }.to raise_error(Phronomy::AgentUnloadedError)
    end
    expect { child.approve(request.execution_id, approval_request_id: request.id) }.to raise_error(Phronomy::AgentUnloadedError)
    token.cancel!
    expect(saved_state(request.execution_id)).to eq(saved)

    loaded = parent_class.load(parent.agent_id, **options)
    recovering = loaded.resume_async(root_id)
    restored = Timeout.timeout(8) { events.pop }
    expect([restored.id, restored.execution_id]).to eq([request.id, request.execution_id])
    expect { recovering.wait_result(timeout: 8) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
    replacement = child_class.get(child.agent_id)
    expect(replacement.approve(restored.execution_id, approval_request_id: restored.id)).to include(output: "child completed")
    expect(loaded.resume_async(root_id).wait_result(timeout: 8)).to include(execution_id: root_id, output: "parent completed")
    expect(recorder.calls.size).to eq(4)
  end

  context "when a restored child requests approval again" do
    let(:effects) { [] }

    def restore_pair(request)
      restored = parent_class.load(parent.agent_id, **options)
      recovering = restored.resume_async(root_id)
      observed = Timeout.timeout(8) { events.pop }
      expect([observed.execution_id, observed.id]).to eq([request.execution_id, request.id])
      expect { recovering.wait_result(timeout: 8) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      restored
    end

    def answer(restored, request, approved: true)
      restored.approve_hosted_child(root_id, execution_id: request.execution_id,
        approval_request_id: request.id, approved: approved)
    end

    before do
      allow_any_instance_of(approval_tool).to receive(:execute).and_wrap_original do |original, query:|
        effects << query
        original.call(query: query)
      end
    end

    it "requires a new parent coordination commit before answering a restored child's saved wait" do
      LLMStub.activate(responses: [dispatch, protected_call])
      original, first, child = start
      detach(original, first)
      allow_any_instance_of(Phronomy::MultiAgent::DurableSubagentCoordinator).to receive(:commit).and_wrap_original do |commit, change|
        raise Phronomy::ExecutionRehydrationRequiredError, "failed recovered parent commit" if change.kind == :terminal
        commit.call(change)
      end

      middle = restore_pair(first)
      participant = Phronomy::MultiAgent::DurableSubagentCoordinator.new(agent_class: parent_class, persistence: stores.multi_agent)
      wait = participant.child_approval_wait(middle.agent_id, root_id, first.execution_id, first.id)
      expect(wait.approval_request_id).to eq(first.id)
      saved = saved_state(first.execution_id)
      expect { answer(middle, first) }.to raise_error(Phronomy::AgentBusyError)
      expect(saved_state(first.execution_id)).to eq(saved)
      expect_live(middle)
      expect(child_class.get(child.agent_id)).not_to be_nil
      expect(effects).to be_empty
    end

    [:revised, :same].each do |definition_change|
      it "refuses a preloaded child after registering an incompatible class with the #{definition_change} definition" do
        LLMStub.activate(responses: [dispatch, protected_call, "child completed"])
        original, first, child = start
        detach(original, first)
        preloaded = child_class.load(child.agent_id, persistence: stores.agent, on_event: options.fetch(:on_event),
          execution_wiring: {cancellation_token: Phronomy::Concurrency::CancellationToken.new})
        expect(Timeout.timeout(8) { events.pop }.id).to eq(first.id)
        definition = (definition_change == :same) ? child_class.agent_definition : {id: "revised-worker", version: 2}
        replacement = Class.new(child_class) { agent_definition(**definition) }
        registration = parent_class.registered_subagents.fetch(:worker)
        parent_class.registered_subagents[:worker] = registration.merge(agent_class: replacement)

        middle = parent_class.load(parent.agent_id, **options)
        expect { middle.resume_async(root_id).wait_result(timeout: 8) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
        saved = stores.agent.executions.load(first.execution_id)
        expect(saved.approval_request.fetch("id")).to eq(first.id)
        expect { answer(middle, first) }.to raise_error(Phronomy::AgentBusyError)
        expect(stores.agent.executions.load(first.execution_id).to_h).to eq(saved.to_h)
        expect_live(preloaded)
        expect(effects).to be_empty
      end
    end

    it "refuses a hosted answer if the parent revision changed after recovery" do
      LLMStub.activate(responses: [dispatch, protected_call])
      original, first, child = start
      detach(original, first)
      middle = restore_pair(first)
      current = stores.agent.executions.load(root_id)
      stores.agent.executions.save(root_id, expected_revision: current.execution_revision,
        execution: current.with(status: current.status))

      saved = saved_state(first.execution_id)
      expect { answer(middle, first) }.to raise_error(Phronomy::AgentBusyError)
      expect(saved_state(first.execution_id)).to eq(saved)
      expect_live(middle)
      expect(child_class.get(child.agent_id)).not_to be_nil
      expect(effects).to be_empty
    end

    [true, false].each do |approve_second|
      it "releases both restored owners and #{approve_second ? "approves" : "rejects"} the second request on the next owner" do
        next_tool = LLMStub.tool_call_response("approval_required_tool", {query: "again"})
        responses = [dispatch, protected_call, next_tool]
        responses << "child completed" if approve_second
        recorder = LLMStub.activate(responses: responses + ["parent completed"])

        original, first, child = start
        detach(original, first)
        middle = restore_pair(first)
        middle_child = child_class.get(child.agent_id)
        decision = answer(middle, first)
        second = Timeout.timeout(8) { events.pop }
        expect(second.execution_id).to eq(first.execution_id)
        expect(second.id).not_to eq(first.id)
        expect(effects).to eq(["check"])

        saved = saved_state(second.execution_id)
        expect { detach(original, second) }.to raise_error(Phronomy::AgentBusyError)
        expect { detach(decision, first) }.to raise_error(Phronomy::AgentBusyError)
        expect { answer(middle, first) }.to raise_error(Phronomy::AgentBusyError)
        expect_live(middle)
        expect_live(middle_child)
        wait = detach(decision, second)
        expect([wait.execution_id, wait.approval_request_id]).to eq([second.execution_id, second.id])
        expect(decision.wait_result(timeout: 8)).to eq(wait)
        [middle, middle_child].each do |agent|
          expect(agent.class.get(agent.agent_id)).to be_nil
          expect { agent.transcript }.to raise_error(Phronomy::AgentUnloadedError)
        end
        expect(saved_state(second.execution_id)).to eq(saved)

        last = restore_pair(second)
        expect { answer(middle, second) }.to raise_error(Phronomy::AgentUnloadedError)
        expect { detach(decision, second) }.to raise_error(Phronomy::AgentBusyError)
        outcome = answer(last, second, approved: approve_second).wait_result(timeout: 8)
        expect(outcome).to include(execution_id: second.execution_id)
        expect(outcome).to include(approve_second ? {output: "child completed"} : {rejected: true})
        expect(last.resume(root_id)).to include(execution_id: root_id, output: "parent completed")
        expect(effects).to eq(approve_second ? ["check", "again"] : ["check"])
        expect(recorder.calls.size).to eq(approve_second ? 5 : 4)
      end
    end
  end

  it "rejects a different root's actual child and a mismatched approval without releasing either root" do
    LLMStub.activate(responses: [dispatch, protected_call, dispatch, protected_call])
    first, request, child = start
    other_parent = parent_class.create(**options)
    second, other, other_child = start(other_parent, SecureRandom.uuid)
    expect { detach(first, other) }.to raise_error(Phronomy::AgentBusyError)
    expect { first.detach!(execution_id: request.execution_id, approval_request_id: other.id) }.to raise_error(Phronomy::AgentBusyError)
    [parent, child, other_parent, other_child].each { |agent| expect_live(agent) }
    expect(detach(first, request).approval_request_id).to eq(request.id)
    expect_live(other_parent)
    expect_live(other_child)
    expect(detach(second, other).approval_request_id).to eq(other.id)
  end

  it "requires a committed parent wait even if an unrelated failure also requests rehydration" do
    LLMStub.activate(responses: [dispatch, protected_call])
    allow_any_instance_of(Phronomy::MultiAgent::DurableSubagentCoordinator).to receive(:commit).and_wrap_original do |commit, change|
      raise Phronomy::ExecutionRehydrationRequiredError, "failed parent commit" if change.kind == :terminal
      commit.call(change)
    end
    handle, request, child = start
    expect { detach(handle, request) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /failed parent commit/)
    expect_live(parent)
    expect_live(child)
  end

  it "leaves both owners in place when an accepted operation holds either Agent" do
    LLMStub.activate(responses: [dispatch, protected_call])
    handle, request, child = start
    [parent, child].each do |busy|
      lease = busy.send(:__acquire_operation!)
      begin
        expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
        expect_live(parent)
        expect_live(child)
      ensure
        lease.release
      end
    end
    expect(detach(handle, request).approval_request_id).to eq(request.id)
  end

  def tool_batch(second_name, second_arguments)
    entries = [["dispatch_to_worker", {input: "first"}], [second_name, second_arguments]]
    calls = entries.map.with_index do |(name, arguments), index|
      {id: "slot-#{index}", type: "function", function: {name: name, arguments: arguments.to_json}}
    end
    {"id" => "dispatch-batch", "object" => "chat.completion", "model" => "stub-model",
     "choices" => [{"index" => 0, "message" => {"role" => "assistant", "tool_calls" => calls},
                    "finish_reason" => "tool_calls"}],
     "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}}
  end

  it "refuses to detach one child when the parent has reserved another slot" do
    LLMStub.activate(responses: [tool_batch("dispatch_to_worker", {input: "second"}), protected_call])
    handle, request, child = start
    extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
      binding_key: Phronomy::MultiAgent::DurableSubagentCoordinator::BINDING_KEY)
    slots = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children")
    expect(slots.map { |slot| slot.fetch("input") }).to contain_exactly("first", "second")
    expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
    expect_live(parent)
    expect_live(child)
    expect(stores.agent.observe_execution(agent_id: child.agent_id, execution_id: request.execution_id)).to be_active
  end

  it "refuses a parent batch containing a native child and an ordinary Tool" do
    LLMStub.activate(responses: [tool_batch("no_approval_tool", {value: "second"}), protected_call])
    handle, request, child = start
    expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
    expect_live(parent)
    expect_live(child)
  end

  [:parent, :child].each do |cancelled|
    it "refuses transfer after a durable cancellation request for the #{cancelled}" do
      LLMStub.activate(responses: [dispatch, protected_call])
      handle, request, child = start
      target, id = (cancelled == :parent) ? [parent, root_id] : [child, request.execution_id]
      stores.agent.request_cancellation(agent_id: target.agent_id, execution_id: id)
      expect { detach(handle, request) }.to raise_error(Phronomy::AgentBusyError)
      expect_live(parent)
      expect_live(child)
    end
  end
end
