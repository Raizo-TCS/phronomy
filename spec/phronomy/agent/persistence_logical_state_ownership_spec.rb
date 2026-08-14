# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent logical-state ownership" do
  FakeOutcome = Struct.new(:content, :tool_calls, :usage, :metadata) do
    def content_present?
      !content.nil?
    end
  end

  let(:persistence) { Phronomy::Persistence::InMemory.new }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "local-state-owner-test", version: 1
      model "local-model"
      context_window 4096
      max_output_tokens 512
      instructions "Test instruction"
    end
  end
  let(:agent) { agent_class.new(persistence: persistence) }
  let(:coordinator) { Phronomy::Agent::ExecutionCoordinator.new(agent) }

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "hydrates a loaded Agent once and then serves Journal projection from local state" do
    agent.add_knowledge("known fact")
    agent_id = agent.agent_id

    expect(persistence.agents).to receive(:load).once.and_call_original
    expect(persistence.journals).to receive(:read).once.and_call_original
    loaded = agent_class.load(agent_id, persistence: persistence)

    expect(persistence.agents).not_to receive(:load)
    expect(persistence.journals).not_to receive(:read)

    records = loaded.journal_projection.context_records
    expect(records.map { |record|
      persistence.contents.fetch_text(record.content_ref)
    }).to include("known fact")
  end

  it "prepares initial and follow-up Manifests without mutable repository reload" do
    # Materialize the Agent-local view before installing the no-reload guards.
    agent

    expect(persistence.agents).not_to receive(:load)
    expect(persistence.executions).not_to receive(:load)
    expect(persistence.journals).not_to receive(:read)

    prepared = coordinator.send(
      :prepare,
      "hello",
      thread_id: "thread-1",
      config: {}
    )
    activation = Phronomy::Agent::AgentExecutionActivation.new(
      execution: prepared.execution,
      agent: agent,
      runtime_projection: prepared.runtime_projection,
      coordinator: coordinator
    )
    activation.invocation = double("AgentInvocation", config: {})

    activation.begin_llm_call(prepared.runtime_projection)
    activation.record_llm_result(
      response: FakeOutcome.new(
        "first answer",
        [],
        {},
        {"model_id" => "local-model"}
      ),
      error: nil,
      streaming: false
    )

    projection = coordinator.prepare_next_llm_call(activation)
    contents = projection.messages.map(&:content)
    expect(contents).to include("hello")
    expect(contents).to include("first answer")
  end

  it "acknowledges only facts captured by the committed snapshot" do
    prepared = coordinator.send(
      :prepare,
      "hello",
      thread_id: "thread-1",
      config: {}
    )
    activation = Phronomy::Agent::AgentExecutionActivation.new(
      execution: prepared.execution,
      agent: agent,
      runtime_projection: prepared.runtime_projection,
      coordinator: coordinator
    )

    first = Phronomy::Agent::StreamEvent.new(
      type: :diagnostic_a,
      payload: {value: "A"}
    )
    later = Phronomy::Agent::StreamEvent.new(
      type: :diagnostic_b,
      payload: {value: "B"}
    )
    activation.record_event(first)
    snapshot = activation.runtime_snapshot
    activation.record_event(later)

    activation.acknowledge_runtime_snapshot(snapshot)

    remaining = activation.runtime_snapshot.fetch(:runtime_events)
    expect(remaining).to eq([later])
  end

  it "keeps facts appended while a Persistence write is in flight" do
    prepared = coordinator.send(
      :prepare,
      "hello",
      thread_id: "thread-1",
      config: {}
    )
    activation = Phronomy::Agent::AgentExecutionActivation.new(
      execution: prepared.execution,
      agent: agent,
      runtime_projection: prepared.runtime_projection,
      coordinator: coordinator
    )
    activation.invocation = double("AgentInvocation", config: {})
    activation.begin_llm_call(prepared.runtime_projection)
    activation.record_llm_result(
      response: FakeOutcome.new(
        "first answer",
        [],
        {},
        {"model_id" => "local-model"}
      ),
      error: nil,
      streaming: false
    )

    save_entered = Queue.new
    allow_save = Queue.new
    original_save = persistence.executions.method(:save)
    allow(persistence.executions).to receive(:save) do |*args, **kwargs|
      save_entered << true
      allow_save.pop
      original_save.call(*args, **kwargs)
    end

    worker = Thread.new { coordinator.prepare_next_llm_call(activation) }
    save_entered.pop

    later = Phronomy::Agent::StreamEvent.new(
      type: :diagnostic_after_snapshot,
      payload: {value: "later"}
    )
    activation.record_event(later)
    allow_save << true
    worker.value

    expect(
      activation.runtime_snapshot.fetch(:runtime_events)
    ).to eq([later])
  end
  it "rejects an external Agent revision advance before the next Manifest is fixed" do
    prepared = coordinator.send(
      :prepare,
      "hello",
      thread_id: "thread-1",
      config: {}
    )
    activation = Phronomy::Agent::AgentExecutionActivation.new(
      execution: prepared.execution,
      agent: agent,
      runtime_projection: prepared.runtime_projection,
      coordinator: coordinator
    )
    activation.invocation = double("AgentInvocation", config: {})
    activation.begin_llm_call(prepared.runtime_projection)
    activation.record_llm_result(
      response: FakeOutcome.new(
        "first answer",
        [],
        {},
        {"model_id" => "local-model"}
      ),
      error: nil,
      streaming: false
    )

    durable_root = persistence.agents.load(agent.agent_id)
    external_root = durable_root.with(
      agent_revision: durable_root.agent_revision + 1,
      context_revision: durable_root.context_revision + 1
    )
    persistence.agents.save(
      agent.agent_id,
      expected_revision: durable_root.agent_revision,
      root: external_root
    )

    local_execution = activation.execution
    expect {
      coordinator.prepare_next_llm_call(activation)
    }.to raise_error(Phronomy::Persistence::ConflictError, /agent revision conflict/)

    expect(activation.execution).to be(local_execution)
    expect(activation.runtime_snapshot.fetch(:llm_results)).not_to be_empty
    expect(agent.agent_root.agent_revision).to eq(durable_root.agent_revision)
  end
end
