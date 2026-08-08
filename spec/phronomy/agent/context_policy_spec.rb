# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Context Policy selection" do
  def candidate(
    id:,
    category:,
    sequence:,
    source_kind: :journal,
    execution_id: "exec-1",
    llm_call_id: nil,
    tool_call_id: nil,
    tool_call_ids: [],
    tokens: 5
  )
    role = case category
    when :tool_message, :tool_result then :tool
    else :assistant
    end
    Phronomy::Agent::ContextCandidate.new(
      candidate_id: id,
      source_kind: source_kind,
      category: category,
      role: role,
      content_ref: "content-#{id}",
      record_id: "record-#{id}",
      agent_id: "agent-1",
      execution_id: execution_id,
      llm_call_id: llm_call_id,
      tool_call_id: tool_call_id,
      sequence: sequence,
      requirement: :optional,
      priority: source_kind == :working ? 100 : 0,
      metadata: {
        "estimated_tokens" => tokens,
        "source_sequence" => sequence,
        "tool_call_ids" => tool_call_ids
      }
    )
  end

  def parts
    {
      unit_builder: Phronomy::Agent::ContextParts::UnitBuilders::DependencyAwareUnitBuilder.new,
      required_context_resolver: Phronomy::Agent::ContextParts::Requirements::RequiredContextResolver.new,
      recent_first_selector: Phronomy::Agent::ContextParts::Selectors::RecentFirstSelector.new,
      token_budget_packer: Phronomy::Agent::ContextParts::Budget::TokenBudgetPacker.new
    }
  end

  def request(candidates, call_mode: :complete, context_window: 200, mandatory: 0)
    Phronomy::Agent::ContextRequest.new(
      agent_id: "agent-1",
      execution_id: "exec-1",
      call_sequence: 2,
      call_mode: call_mode,
      candidates: candidates,
      token_budget: Phronomy::LlmContextWindow::TokenBudget.new(
        context_window: context_window,
        max_output_tokens: 0
      ),
      model_config: {},
      previous_manifest: nil,
      required_coverage: [],
      parts: parts,
      metadata: {"mandatory_token_estimate" => mandatory}
    )
  end

  it "does not use execution_id as an atomic selection boundary" do
    candidates = [
      candidate(id: "a", category: :assistant_message, sequence: 1),
      candidate(id: "b", category: :assistant_message, sequence: 2)
    ]

    units = parts.fetch(:unit_builder).build(candidates)
    expect(units.map(&:candidate_ids)).to contain_exactly(["a"], ["b"])
  end

  it "keeps one assistant message and all matching Tool messages atomic" do
    candidates = [
      candidate(
        id: "assistant",
        category: :assistant_message,
        sequence: 1,
        llm_call_id: "llm-1",
        tool_call_ids: %w[call-a call-b]
      ),
      candidate(
        id: "result-a",
        category: :tool_message,
        sequence: 2,
        llm_call_id: "llm-1",
        tool_call_id: "call-a"
      ),
      candidate(
        id: "result-b",
        category: :tool_message,
        sequence: 3,
        llm_call_id: "llm-1",
        tool_call_id: "call-b"
      )
    ]

    units = parts.fetch(:unit_builder).build(candidates)
    expect(units.length).to eq(1)
    expect(units.first.kind).to eq(:tool_exchange)
    expect(units.first.candidate_ids).to contain_exactly(
      "assistant", "result-a", "result-b"
    )
  end

  it "uses the same Tool dependency rule for imported messages without llm_call_id" do
    candidates = [
      candidate(
        id: "assistant",
        category: :assistant_message,
        sequence: 10,
        execution_id: nil,
        llm_call_id: nil,
        tool_call_ids: ["call-a"]
      ),
      candidate(
        id: "result",
        category: :tool_message,
        sequence: 11,
        execution_id: nil,
        llm_call_id: nil,
        tool_call_id: "call-a"
      )
    ]

    units = parts.fetch(:unit_builder).build(candidates)
    expect(units.length).to eq(1)
    expect(units.first.candidate_ids).to contain_exactly("assistant", "result")
  end

  it "requires only the latest current Tool exchange and may drop older working history" do
    candidates = [
      candidate(id: "old", category: :assistant_message, sequence: 1,
        source_kind: :working, tokens: 80),
      candidate(id: "assistant", category: :assistant_message, sequence: 2,
        source_kind: :working, llm_call_id: "llm-2", tool_call_ids: ["call"], tokens: 10),
      candidate(id: "result", category: :tool_message, sequence: 3,
        source_kind: :working, llm_call_id: "llm-2", tool_call_id: "call", tokens: 10)
    ]
    context_request = request(candidates, context_window: 40, mandatory: 5)

    plan = Phronomy::Agent::ContextPolicies::Default.new.call(context_request)
    validated = Phronomy::Agent::ContextPlanValidator.new.validate!(
      request: context_request,
      plan: plan
    )

    expect(validated.selected_candidates.map(&:candidate_id)).to contain_exactly("assistant", "result")
    expect(validated.selected_units.first.requirement).to eq(:protocol_required)
  end
end
