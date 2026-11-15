# frozen_string_literal: true

require "spec_helper"
require_relative "support/durable_coordination"

RSpec.describe "Durable authorization argument evidence" do
  include_context "durable coordination runtime"

  def batch_key = Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY

  def team_call_response
    calls = [
      {"id" => "enqueue", "name" => "enqueue_task", "arguments" => {"description" => "task-one", "metadata" => nil}},
      {"id" => "finalize", "name" => "finalize", "arguments" => {}}
    ]
    Phronomy::LLMAdapter::Response.from_h(role: :assistant, content: nil, tool_calls: calls)
  end

  def provider_response
    {"id" => "authorized-batch", "object" => "chat.completion", "model" => "stub-model",
     "choices" => [{"index" => 0, "message" => {"role" => "assistant", "content" => nil,
                                                "tool_calls" => team_call_response.tool_calls.map { |call|
                                                  {"id" => call.id, "type" => "function",
                                                   "function" => {"name" => call.name, "arguments" => JSON.generate(call.arguments)}}
                                                }}, "finish_reason" => "tool_calls"}]}
  end

  def coordinator_checkpoint(team, phase)
    captured = nil
    store.after_commit = proc do |backend|
      run = backend.multi_agent.runs(team.team_id).first
      next unless run && !captured
      begin
        coordinator = backend.agent.executions.load(run.coordinator.fetch("execution_id"))
        captured = backend.snapshot if coordinator.phase == phase
      rescue Phronomy::Persistence::NotFoundError
        nil
      end
    end
    LLMStub.activate(responses: [provider_response, "queued", "worker-result"])
    team.invoke("plan")
    expect(captured).not_to be_nil
    captured
  end

  def assert_validated_projection(backend, coordinator)
    batch = coordinator.metadata.fetch(batch_key)
    expect(batch.map { |entry| entry.fetch("validated_arguments") }).to eq([
      {"description" => "task-one"}, {}
    ])
    expect(batch.first.fetch("arguments")).to eq("description" => "task-one", "metadata" => nil)
    backend.atomic do |scope|
      values = backend.agent.authorized_operations(scope, agent_id: coordinator.agent_id,
        execution_id: coordinator.execution_id, invocation_id: batch.last.fetch("tool_invocation_id"),
        name: "finalize", arguments: {}, names: %w[enqueue_task finalize])
      expect(values.map(&:arguments)).to eq([{"description" => "task-one"}, {}])
    end
  end

  it "projects validated operations from a fresh backend before replaying a saved Team dispatch" do
    team = team_class.create(team_id: "authorized-team", persistence: store.multi_agent)
    restored = reboot(coordinator_checkpoint(team, :dispatching_tools))
    loaded = team_class.load(team.team_id, persistence: restored.multi_agent)
    run = loaded.executions.first
    coordinator = restored.agent.executions.load(run.coordinator.fetch("execution_id"))
    assert_validated_projection(restored, coordinator)

    LLMStub.activate(responses: ["queued", "worker-result"])
    expect(loaded.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect(loaded.executions.first.tasks.size).to eq(1)
  end

  it "revalidates recovered provider calls before Team authorization, including a second restart" do
    team = team_class.create(team_id: "provider-recovery-team", persistence: store.multi_agent)
    restored = reboot(coordinator_checkpoint(team, :calling_llm))
    events = Queue.new
    loaded = team_class.load(team.team_id, persistence: restored.multi_agent,
      on_event: ->(event) { events << event.payload if event.type == :recovery_resolution_required })
    run = loaded.executions.first
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    event = Timeout.timeout(3) { events.pop }
    coordinator = loaded.send(:coordinator_class, run.team_execution_id).get(run.coordinator.fetch("agent_id"))
    recovery_snapshot = nil
    restored.after_commit = proc do |backend|
      current = backend.agent.executions.load(run.coordinator.fetch("execution_id"))
      recovery_snapshot ||= backend.snapshot if current.phase == :recovery_provider_completed
    end
    projected_batches = []
    allow(restored.agent).to receive(:authorized_operations).and_wrap_original do |original, *args, **keywords|
      current = restored.agent.executions.load(keywords.fetch(:execution_id))
      projected_batches << current.metadata.fetch(batch_key)
      expect(current.metadata.fetch(batch_key)).to all(have_key("validated_arguments"))
      original.call(*args, **keywords)
    end
    LLMStub.activate(responses: ["queued", "worker-result"])
    coordinator.resolve_async(event.fetch(:execution_id), expected_execution_revision: event.fetch(:execution_revision),
      subject: event.fetch(:subject), outcome: :succeeded, result: team_call_response.to_h).wait_result(timeout: 3)
    expect(loaded.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect(projected_batches).not_to be_empty
    expect(recovery_snapshot).not_to be_nil

    restarted = reboot(recovery_snapshot)
    saved = restarted.agent.executions.load(run.coordinator.fetch("execution_id"))
    expect(saved.metadata.fetch(batch_key)).to all(include("status" => "authorized"))
    expect(saved.metadata.fetch(batch_key)).to all(satisfy { |entry| !entry.key?("validated_arguments") })
    # Recovery placeholders describe provider output; Tool preflight must replace
    # them before the Store treats an operation as authorized to change Team state.
    saved_team = restarted.multi_agent.team_executions.load(run.team_execution_id)
    expect(saved_team.tasks).to be_empty
    expect(saved_team.metadata.fetch("operations")).to be_empty
    expect do
      restarted.atomic do |scope|
        restarted.agent.authorized_operations(scope, agent_id: saved.agent_id, execution_id: saved.execution_id,
          invocation_id: saved.metadata.fetch(batch_key).last.fetch("tool_invocation_id"),
          name: "finalize", arguments: {}, names: %w[enqueue_task finalize])
      end
    end.to raise_error(KeyError, /validated_arguments/)
    expect(restarted.multi_agent.team_executions.load(run.team_execution_id).to_h).to eq(saved_team.to_h)
    dispatched = []
    allow(restarted.agent).to receive(:authorized_operations).and_wrap_original do |original, *args, **keywords|
      current = restarted.agent.executions.load(keywords.fetch(:execution_id))
      dispatched << current.metadata.fetch(batch_key)
      expect(current.metadata.fetch(batch_key)).to all(have_key("validated_arguments"))
      original.call(*args, **keywords)
    end
    reloaded = team_class.load(team.team_id, persistence: restarted.multi_agent)
    LLMStub.activate(responses: ["queued", "worker-result"])
    expect(reloaded.resume(run.team_execution_id).first.fetch("result")).to eq("worker-result")
    expect(dispatched).not_to be_empty
    expect(reloaded.executions.first.tasks.size).to eq(1)
  end

  it "preserves coerced approval arguments through a fresh Runtime and dispatch checkpoint" do
    operation = Class.new(Phronomy::Tool::Base) do
      tool_name "approved_count"
      description "Count after approval"
      param :count, type: :integer, desc: "Count"
      on_schema_error :coerce
      requires_approval true
      def execute(count:) = count
    end
    owner = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "approval-argument-owner", version: 1
      model "gpt-4o-mini"
      provider :openai
      tools operation => nil
    end
    approvals = Queue.new
    agent = owner.create(agent_id: "approved-owner", persistence: store.agent,
      on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
    LLMStub.activate(responses: [LLMStub.tool_call_response("approved_count", {count: "2"})])
    agent.invoke_async("count")
    request = Timeout.timeout(3) { approvals.pop }
    suspended = store.agent.executions.load(request.execution_id)
    expect(suspended.metadata.fetch(batch_key).first.fetch("validated_arguments")).to eq("count" => 2)

    restored = reboot(store.snapshot)
    loaded = owner.load(agent.agent_id, persistence: restored.agent,
      on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
    recovered_request = Timeout.timeout(3) { approvals.pop }
    checkpoint = nil
    restored.after_commit = proc do |backend|
      current = backend.agent.executions.load(request.execution_id)
      checkpoint ||= backend.snapshot if current.phase == :dispatching_tools
    end
    LLMStub.activate(responses: ["approved"])
    expect(loaded.approve(request.execution_id, approval_request_id: recovered_request.id)[:output]).to eq("approved")
    expect(checkpoint).not_to be_nil

    saved = reboot(checkpoint)
    execution = saved.agent.executions.load(request.execution_id)
    entry = execution.metadata.fetch(batch_key).first
    expect(entry.fetch("arguments")).to eq("count" => "2")
    saved.atomic do |scope|
      projected = saved.agent.authorized_operations(scope, agent_id: agent.agent_id,
        execution_id: request.execution_id, invocation_id: entry.fetch("tool_invocation_id"),
        name: "approved_count", arguments: {"count" => 2}, names: ["approved_count"])
      expect(projected.first.arguments).to eq("count" => 2)
    end
  end
end
