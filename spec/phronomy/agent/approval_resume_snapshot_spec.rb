# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Approval resume snapshot ownership (F0/F2/F3; no X0)" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "approval-snapshot-owner", version: 1
      model "local-model"
    end
  end
  let(:agent) { agent_class.new(agent_id: "approval-owner", persistence: Phronomy::Persistence.in_memory) }
  let(:coordinator) { agent.send(:execution_coordinator) }
  let(:runtime) { Phronomy::Runtime.instance }
  let(:registry) { Phronomy::Agent::ExecutionRegistry.for(runtime.event_loop) }
  let(:execution) do
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id, execution_id: "approval-execution",
      kind: :user_message, channel: :llm, role: :user,
      content_ref: agent.persistence.contents.put_text("input"),
      context_generation: agent.agent_root.transcript_generation,
      context_candidate: true
    )
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: record, execution_id: "approval-execution")
      .with(status: :active).with(status: :suspended, phase: :approval,
        approval_request: {"id" => "approval-1"})
  end
  let(:arguments) { {"nested" => [{"query" => +"before"}]} }
  let(:saved_result) { {"items" => [+"saved"]} }
  let(:child) do
    double("tool invocation", id: +"child-1", tool_call_id: +"call-1",
      tool_name: +"lookup", raw_arguments: arguments, status: :completed,
      execution_completed?: true, result: saved_result)
  end
  let(:invocation) { double("invocation", tool_invocations: [child], tool_batch_llm_call_id: +"llm-1") }
  let(:submitted) { [] }

  def on_loop(&action)
    completed = Phronomy::TaskResult.deferred(name: "approval-contract-loop")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completed.complete(action.call)
    rescue => error
      completed.fail(error)
    end
    registry.post(Struct.new(:coordinator).new(handler), completion: completed)
    completed.wait_result(timeout: 3)
  end

  def install(**changes)
    on_loop do
      token = Object.new
      registry.admit_agent_execution(agent.agent_id, owner_token: token)
      registry.bind_agent_execution_admission(agent.agent_id,
        owner_token: token, execution_id: execution.execution_id)
      registry.mark_agent_execution_admission(agent.agent_id,
        execution_id: execution.execution_id, state: :suspended)
      registry.install_agent_execution(execution_id: execution.execution_id, agent: agent, coordinator: coordinator,
        execution: execution, runtime_projection: nil, base_manifest: nil,
        invocation: invocation, fsm_session_id: nil, **changes)
    end
  end

  def request(**changes)
    Phronomy::Agent::ExecutionCoordinator::ResumeCommand.new(coordinator: coordinator, execution_id: execution.execution_id,
      approval_request_id: "approval-1", approved: true, config: {}.freeze,
      result_task: Phronomy::TaskResult.deferred(name: "approval-observer"), **changes)
  end

  def submit(command = request)
    on_loop { coordinator.deliver_on_event_loop(command) }
    command
  end

  def assert_frozen_tree(value)
    expect(value).to be_frozen
    case value
    when Hash then value.each { |key, item|
      assert_frozen_tree(key)
      assert_frozen_tree(item)
    }
    when Array then value.each { |item| assert_frozen_tree(item) }
    end
  end

  before do
    allow(runtime.offload).to receive(:submit) do |on_full:, &work|
      expect(on_full).to eq(:raise)
      task = Phronomy::TaskResult.deferred(name: "held-approval-worker")
      submitted << [work, task]
      task
    end
    # Observe the exact command when its deferred worker eventually executes.
    worker = coordinator.instance_variable_get(:@approval_resume_commit)
    allow(worker).to receive(:commit) { |operation| operation }
  end

  after do
    on_loop do
      registry.release_agent_execution(execution.execution_id)
      registry.release_agent_execution_admission(agent.agent_id, execution_id: execution.execution_id)
    end
    Phronomy.reset_runtime!
  end

  it "copies nested arguments, results and identifiers before the worker runs" do
    install
    submit
    arguments["nested"].first["query"].replace("after")
    saved_result["items"].first.replace("changed")
    child.tool_name.replace("another-tool")
    child.tool_call_id.replace("another-call")
    invocation.tool_batch_llm_call_id.replace("another-llm")
    snapshot = submitted.first.first.call.tool_batch_snapshot

    expect(snapshot.first).to include(
      "tool_name" => "lookup", "tool_call_id" => "call-1", "llm_call_id" => "llm-1",
      "raw_arguments" => {"nested" => [{"query" => "before"}]},
      "arguments" => {"nested" => [{"query" => "before"}]},
      "result" => {"items" => ["saved"]}
    )
    assert_frozen_tree(snapshot)
    expect(arguments["nested"].first["query"]).not_to be_frozen
  end

  it "keeps overlapping approvals independent even when workers execute in reverse order" do
    install
    submit
    arguments["nested"].first["query"].replace("second")
    submit
    second = submitted.last.first.call.tool_batch_snapshot
    first = submitted.first.first.call.tool_batch_snapshot
    expect(first.first.fetch("arguments")["nested"].first["query"]).to eq("before")
    expect(second.first.fetch("arguments")["nested"].first["query"]).to eq("second")
    expect(first).not_to equal(second)
  end

  it "does not capture a stale request or replace an already queued snapshot" do
    install
    submit
    arguments["nested"].first["query"].replace("stale")
    expect(Phronomy::Agent::ExecutionMetadata).not_to receive(:build_tool_batch_snapshot)
    stale = submit(request(approval_request_id: "old-request"))
    expect { stale.result_task.wait_result(timeout: 3) }.to raise_error(ArgumentError, /does not match/)
    expect(submitted.size).to eq(1)
    expect(submitted.first.first.call.tool_batch_snapshot.first["arguments"]["nested"].first["query"])
      .to eq("before")
  end

  [:missing, :other_owner, :active].each do |invalid|
    it "rejects #{invalid} state before reading its invocation" do
      case invalid
      when :other_owner then install(agent: Object.new)
      when :active then install(execution: execution.with(status: :active))
      when :missing then nil
      end
      expect(Phronomy::Agent::ExecutionMetadata).not_to receive(:build_tool_batch_snapshot)
      rejected = submit
      error = (invalid == :missing) ? Phronomy::ExecutionRehydrationRequiredError : ArgumentError
      expect { rejected.result_task.wait_result(timeout: 3) }.to raise_error(error)
      expect(submitted).to be_empty
    end
  end

  it "captures a fresh snapshot after Offload rejection and restores suspended admission" do
    install
    allow(registry).to receive(:mark_agent_execution_admission).and_call_original
    allow(runtime.offload).to receive(:submit).and_raise(Phronomy::Error, "queue full")
    rejected = submit
    expect { rejected.result_task.wait_result(timeout: 3) }.to raise_error(Phronomy::Error, "queue full")
    expect(registry).to have_received(:mark_agent_execution_admission)
      .with(agent.agent_id, execution_id: execution.execution_id, state: :suspended)
    arguments["nested"].first["query"].replace("retry")
    allow(runtime.offload).to receive(:submit) do |**_, &work|
      submitted << [work, Phronomy::TaskResult.deferred]
      submitted.last.last
    end
    submit
    expect(submitted.first.first.call.tool_batch_snapshot.first["arguments"]["nested"].first["query"])
      .to eq("retry")
  end

  it "preserves the distinction between an absent invocation and an empty batch" do
    install(invocation: nil)
    submit
    expect(submitted.first.first.call.tool_batch_snapshot).to be_nil
    allow(invocation).to receive(:tool_invocations).and_return([])
    on_loop { registry.replace_agent_execution(execution.execution_id, invocation: invocation) }
    submit
    expect(submitted.last.first.call.tool_batch_snapshot).to eq([])
    expect(submitted.last.first.call.tool_batch_snapshot).to be_frozen
  end

  [:cancelled, :next_approval].each do |replacement|
    it "discards a late commit result after #{replacement} without resuming a session (F3)" do
      install
      pending = submit
      operation = submitted.first.first.call
      current = if replacement == :cancelled
        execution.with(status: :cancelled)
      else
        execution.with(approval_request: {"id" => "approval-2"})
      end
      on_loop { registry.replace_agent_execution(execution.execution_id, execution: current) }
      expect(coordinator).not_to receive(:execution_session_runner)
      submitted.first.last.complete(Phronomy::Agent::ApprovalResumeCommit::Result.new(
        execution: operation.execution.with(status: :active), root: operation.root
      ))
      expect { pending.result_task.wait_result(timeout: 3) }.to raise_error(Phronomy::Error, /stale approval/)
      expect(on_loop { registry.agent_execution_state(execution.execution_id).execution }).to equal(current)
    end
  end

  it "keeps admission fail-closed and does not resume a session on commit error (F1)" do
    install
    pending = submit
    allow(registry).to receive(:mark_agent_execution_admission).and_call_original
    expect(coordinator).not_to receive(:execution_session_runner)
    submitted.first.last.fail(IOError.new("approval response lost"))
    expect { pending.result_task.wait_result(timeout: 3) }.to raise_error(IOError, /response lost/)
    expect(registry).to have_received(:mark_agent_execution_admission)
      .with(agent.agent_id, execution_id: execution.execution_id, state: :recovery_required)
    expect(on_loop { registry.agent_execution_state(execution.execution_id).execution }).to equal(execution)
  end
end
