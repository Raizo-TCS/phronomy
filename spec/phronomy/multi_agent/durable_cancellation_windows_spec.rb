# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Durable parent cancellation windows" do
  include_context "durable coordination runtime"

  [:before_commit, :after_commit].each do |window|
    it "retains intent received #{window}, including after a second restart" do
      parent = parent_class.create(agent_id: "cancel-window", persistence: store.agent, coordination_store: store.multi_agent)
      restored = reboot(unresolved_child_checkpoint(parent))
      ready, release, delivered = Queue.new, Queue.new, Queue.new
      claimed = false
      claim_lock = Mutex.new
      allow(Phronomy::Agent::ExecutionOutcomeCommitter).to receive(:new).and_wrap_original do |original, **args|
        committer = original.call(**args)
        if args.fetch(:agent).agent_id == parent.agent_id
          allow(committer).to receive(:commit_outcome).and_wrap_original do |commit, operation|
            selected = claim_lock.synchronize do
              next false if claimed
              claimed = true
            end
            if selected
              expect(operation.terminal_view.cancel_requested).to be(false)
              result = commit.call(operation) if window == :after_commit
              ready << operation
              raise "Cancellation release gate timed out" unless release.pop(timeout: 5)
              result || commit.call(operation)
            else
              commit.call(operation)
            end
          end
        end
        committer
      end
      allow(Phronomy::Agent::ExactExecution).to receive(:new).and_wrap_original do |original, *args|
        observer = original.call(*args)
        if args.first.agent_id == parent.agent_id
          allow(observer).to receive(:deliver_on_event_loop).and_wrap_original do |deliver, command|
            deliver.call(command).tap { delivered << true }
          end
        end
        observer
      end
      llm = LLMStub.activate(responses: ["must not replay"])
      loaded = parent_class.load(parent.agent_id, persistence: restored.agent, coordination_store: restored.multi_agent)
      operation = ready.pop(timeout: 5)
      expect(operation).not_to be_nil
      id = operation.execution_id
      token = Phronomy::Concurrency::CancellationToken.new.cancel!
      task = loaded.resume_async(id, config: {cancellation_token: token})
      expect(delivered.pop(timeout: 5)).to be(true)
      expect(restored.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: id)).to be(true)
      revision = operation.expected_execution_revision + ((window == :after_commit) ? 1 : 0)
      expect(restored.agent.executions.load(id).execution_revision).to eq(revision)
      release << true
      expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      waiting = restored.agent.executions.load(id)
      expect(waiting).to be_active
      expect(waiting.metadata["cancellation_requested"]).to eq(window == :before_commit)
      extension = restored.agent.contents.fetch_json(waiting.metadata.fetch("execution_extension").fetch("state_ref"))
      expect(extension.fetch("cancel_requested")).to eq(window == :before_commit)
      child = restored.agent.executions.load(extension.fetch("children").first.fetch("execution_id"))
      expect(child).to be_active
      expect(child.phase).to eq(:calling_llm)
      restarted = reboot(restored.snapshot)
      loaded = parent_class.load(parent.agent_id, persistence: restarted.agent, coordination_store: restarted.multi_agent)
      expect { loaded.resume(id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      expect(restarted.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: id)).to be(true)
      expect(restarted.agent.executions.load(id).metadata["cancellation_requested"]).to be(true)
      expect(llm.calls).to be_empty
    ensure
      release << true if release
    end
  end

  it "records intent after the previous owner has released an unresolved parent" do
    parent = parent_class.create(agent_id: "cancel-released", persistence: store.agent, coordination_store: store.multi_agent)
    restored = reboot(unresolved_child_checkpoint(parent))
    llm = LLMStub.activate(responses: ["must not replay"])
    loaded = parent_class.load(parent.agent_id, persistence: restored.agent, coordination_store: restored.multi_agent)
    id = restored.agent.runs(parent.agent_id).first.execution_id
    expect { loaded.resume(id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(restored.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: id)).to be(false)
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    expect { loaded.resume(id, config: {cancellation_token: token}) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    expect(restored.agent.cancellation_requested?(agent_id: parent.agent_id, execution_id: id)).to be(true)
    expect(restored.agent.executions.load(id).metadata["cancellation_requested"]).to be(true)
    expect(llm.calls).to be_empty
  end
end
