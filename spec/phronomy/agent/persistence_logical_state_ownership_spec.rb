# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent logical-state ownership" do
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
  let(:root) { File.expand_path("../../..", __dir__) }

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

  it "keeps mutable Agent repository reload out of ExecutionCoordinator" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )

    expect(coordinator).not_to match(/(?:tx|persistence)\.agents\.load/)
    expect(coordinator).not_to match(/(?:tx|persistence)\.executions\.load/)
    expect(coordinator).not_to match(/(?:tx|persistence)\.journals\.read/)
  end

  it "uses the local Agent watermark before fixing a follow-up Manifest" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )
    followup = coordinator
      .split("def perform_followup_preparation", 2)
      .fetch(1)
      .split("def apply_followup_preparation_on_event_loop", 2)
      .first

    expect(followup.index("assert_local_durable_base!")).to be <
      followup.index("ContextAssembler.new")
    expect(followup.index("ContextAssembler.new")).to be <
      followup.index("tx.executions.save")
  end

  it "applies committed AgentRoot and Journal advances only through the EventLoop apply helper" do
    coordinator = File.read(
      File.join(root, "lib/phronomy/agent/execution_coordinator.rb")
    )

    mutation_sites = coordinator.lines.each_index.filter_map do |index|
      line = coordinator.lines[index]
      next unless line.include?("__replace_root") || line.include?("_append_journal_records")
      [index + 1, line]
    end

    expect(mutation_sites.length).to eq(2)
    apply_section = coordinator
      .split("def apply_agent_live_state", 2)
      .fetch(1)
      .split(/^      def /, 2)
      .first
    expect(apply_section).to include("_append_journal_records")
    expect(apply_section).to include("__replace_root")
  end

  it "keeps uncommitted Provider and runtime facts in the EventLoop-owned AgentInvocation" do
    invocation = Phronomy::Agent::AgentInvocation.new(
      agent: agent,
      input: "hello",
      config: {execution_id: "execution-local"},
      execution_id: "execution-local"
    )
    projection = Struct.new(:manifest_ref).new("sha256:manifest")
    invocation.begin_llm_call!(projection, llm_call_id: "llm-1")
    current = Phronomy::Agent::LLMOperationResult.new(
      llm_call_id: "llm-1",
      error: Phronomy::Error.new("provider failure"),
      streaming: false
    )
    invocation.handle_fsm_event(
      Phronomy::Event.new(type: :llm_failed, target_id: "fsm-1", payload: current)
    )

    snapshot = invocation.runtime_snapshot
    expect(snapshot.fetch(:llm_results).fetch(0).fetch(:llm_call_id)).to eq("llm-1")
    expect(snapshot.fetch(:active_call)).to be_nil
  end
end
