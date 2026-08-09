# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Journal-backed Agent Knowledge" do
  let(:persistence) { Phronomy::Persistence::InMemory.new }

  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "journal-backed-knowledge-test", version: 1
      model "local-model"
      context_window 1_000
      max_output_tokens 100
      instructions "Base instruction"
    end
  end

  def execution_for(agent, input: "hello")
    root = agent.agent_root
    input_ref = agent.persistence.contents.put_text(input)
    input_record = Phronomy::Agent::JournalRecord.new(
      agent_id: agent.agent_id,
      kind: :external_message,
      channel: :external,
      role: :user,
      content_ref: input_ref,
      context_generation: root.transcript_generation,
      context_candidate: true
    )
    execution = Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: input_record,
      metadata: {
        "current_input_ref" => input_ref,
        "current_input_record_id" => input_record.record_id
      }
    ).with(
      execution_revision: 0,
      working_records: [input_record]
    )
    [execution, input_record]
  end

  def build_initial(agent, input: "hello", patch: Phronomy::Agent::LLMInputPatch.empty)
    execution, = execution_for(agent, input: input)
    Phronomy::Agent::ContextAssembler.new(
      agent: agent,
      persistence: agent.persistence
    ).build_initial(
      input: input,
      agent_root: agent.agent_root,
      execution: execution,
      patch: patch
    ).first
  end

  it "registers creation-time Knowledge as Journal context candidates, not transcript messages" do
    agent = agent_class.new(
      persistence: persistence,
      knowledge: ["Customer tier: enterprise", "Customer locale: ja-JP"]
    )

    knowledge = agent.journal_projection.context_records.select { |record| record.kind == :knowledge }

    expect(knowledge.map { |record| persistence.contents.fetch_text(record.content_ref) })
      .to eq(["Customer tier: enterprise", "Customer locale: ja-JP"])
    expect(agent.transcript).to be_empty
  end

  it "supports creation-time Knowledge through .create" do
    agent = agent_class.create(
      persistence: persistence,
      knowledge: ["Policy: uploads require malware scanning"]
    )

    knowledge = agent.journal_projection.context_records.select { |record| record.kind == :knowledge }
    expect(knowledge.length).to eq(1)
    expect(persistence.contents.fetch_text(knowledge.first.content_ref))
      .to eq("Policy: uploads require malware scanning")
  end

  it "appends Knowledge after creation and preserves it across reload" do
    agent = agent_class.new(persistence: persistence)
    agent.add_knowledge(
      "Customer locale: ja-JP",
      metadata: {"origin" => "customer_profile"}
    )

    loaded = agent_class.load(agent.agent_id, persistence: persistence)
    record = loaded.journal_projection.context_records.find { |candidate| candidate.kind == :knowledge }

    expect(record).not_to be_nil
    expect(persistence.contents.fetch_text(record.content_ref)).to eq("Customer locale: ja-JP")
    expect(record.metadata).to eq("origin" => "customer_profile")
  end

  it "rejects persistent Knowledge mutation while an execution is active" do
    agent = agent_class.new(persistence: persistence)
    execution, = execution_for(agent)
    persistence.executions.create_active(execution)

    expect { agent.add_knowledge("late mutation") }
      .to raise_error(Phronomy::AgentBusyError)
  end

  it "clear_knowledge! invalidates earlier Knowledge without deleting raw Journal records" do
    agent = agent_class.new(persistence: persistence, knowledge: ["old knowledge"])
    old_record = agent.journal_projection.context_records.find { |record| record.kind == :knowledge }

    agent.clear_knowledge!
    agent.add_knowledge("new knowledge")

    active = agent.journal_projection.context_records.select { |record| record.kind == :knowledge }
    raw = agent.journal_projection.records.select { |record| record.kind == :knowledge }

    expect(active.map { |record| persistence.contents.fetch_text(record.content_ref) })
      .to eq(["new knowledge"])
    expect(raw.map(&:record_id)).to include(old_record.record_id)
    expect(raw.length).to eq(2)
  end

  it "clear_transcript! preserves Knowledge" do
    agent = agent_class.new(
      persistence: persistence,
      context: [{role: :user, content: "old conversation"}],
      knowledge: ["persistent knowledge"]
    )

    agent.clear_transcript!

    expect(agent.transcript).to be_empty
    active = agent.journal_projection.context_records.select { |record| record.kind == :knowledge }
    expect(active.length).to eq(1)
  end

  it "reset_context! invalidates both transcript and Knowledge" do
    agent = agent_class.new(
      persistence: persistence,
      context: [{role: :user, content: "old conversation"}],
      knowledge: ["old knowledge"]
    )

    agent.reset_context!

    expect(agent.transcript).to be_empty
    expect(agent.journal_projection.context_records).to be_empty
  end

  it "selects persistent Knowledge through Context Policy and places it before history" do
    agent = agent_class.new(
      persistence: persistence,
      context: [{role: :user, content: "historical message"}],
      knowledge: ["persistent knowledge"]
    )

    manifest = build_initial(agent)
    categories = manifest.segments.map(&:category)

    expect(categories).to include(:knowledge)
    expect(categories.index(:knowledge)).to be < categories.index(:external_message)
    expect(categories.index(:external_message)).to be < categories.index(:current_input)
  end

  it "allows Context Policy to omit oversized persistent Knowledge" do
    tight_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "journal-backed-knowledge-tight-test", version: 1
      model "local-model"
      context_window 200
      max_output_tokens 20
      instructions "Base instruction"
    end
    agent = tight_class.new(
      persistence: persistence,
      knowledge: ["K" * 20_000]
    )

    manifest = build_initial(agent)

    expect(manifest.segments.map(&:category)).not_to include(:knowledge)
    expect(manifest.segments.map(&:category)).to include(:instruction, :current_input)
  end

  it "routes before_llm_input Knowledge through Context Policy without journaling it" do
    agent = agent_class.new(persistence: persistence)
    patch = Phronomy::Agent::LLMInputPatch.new(
      segment_candidates: [
        {
          content: "temporary retrieved context",
          category: :knowledge,
          role: :user,
          metadata: {"origin" => "retrieval"}
        }
      ]
    )

    manifest = build_initial(agent, patch: patch)
    segment = manifest.segments.find { |item| item.category == :knowledge }

    expect(segment).not_to be_nil
    expect(segment.metadata["origin"]).to eq("retrieval")
    expect(agent.journal_projection.records.none? { |record| record.kind == :knowledge }).to be(true)
  end

  it "does not treat before_llm_input Knowledge as mandatory" do
    tight_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "journal-backed-hook-knowledge-tight-test", version: 1
      model "local-model"
      context_window 200
      max_output_tokens 20
      instructions "Base instruction"
    end
    agent = tight_class.new(persistence: persistence)
    patch = Phronomy::Agent::LLMInputPatch.new(
      segment_candidates: [
        {content: "K" * 20_000, category: :knowledge, role: :user}
      ]
    )

    manifest = build_initial(agent, patch: patch)

    expect(manifest.segments.map(&:category)).not_to include(:knowledge)
  end
end
