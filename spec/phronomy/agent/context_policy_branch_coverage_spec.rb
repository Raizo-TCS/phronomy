# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Context Policy branch coverage" do
  let(:provenance) do
    Phronomy::Agent::ContextPolicyInput::Provenance.new(origin: :journal)
  end

  def conversation_item(id:, kind:, sequence:, tool_call_id: nil, tool_call_ids: [], required: false)
    content = if kind == :assistant_message
      {"role" => "assistant", "content" => nil,
       "tool_calls" => tool_call_ids.map { |call_id| {"id" => call_id, "name" => "tool", "arguments" => {}} }}
    elsif kind == :tool_message
      {"role" => "tool", "content" => "ok", "tool_call_id" => tool_call_id}
    else
      id
    end
    Phronomy::Agent::ContextPolicyInput::ConversationItem.new(
      id: id, kind: kind, role: ((kind == :tool_message) ? :tool : :assistant),
      content: content, content_format: content.is_a?(String) ? :text : :json,
      sequence: sequence, estimated_tokens: 5, required: required,
      provenance: provenance, tool_call_id: tool_call_id,
      tool_call_ids: tool_call_ids, delivery: :chat_message, metadata: {}
    )
  end

  def empty_input(conversation: [])
    Phronomy::Agent::ContextPolicyInput.new(
      agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
      instruction: [], knowledge: [], tools: [], conversation: conversation,
      token_budget: nil, model_config: {}, previous_manifest: nil, metadata: {}
    )
  end

  describe Phronomy::Agent::ContextPlanValidator do
    it "rejects a non-ContextPlan" do
      expect { described_class.new.validate!(input: empty_input, plan: Object.new) }
        .to raise_error(ArgumentError, /expected.*ContextPlan/)
    end

    it "rejects duplicate Plan item IDs" do
      item = conversation_item(id: "same", kind: :external_message, sequence: 1)
      policy_input = empty_input(conversation: [[item]])
      generated = Phronomy::Agent::ContextPolicyInput::KnowledgeItem.new(
        id: "same", kind: :knowledge, role: :user, content: "x",
        content_format: :text, estimated_tokens: 1, required: false,
        provenance: Phronomy::Agent::ContextPolicyInput::Provenance.new(origin: :policy_generated),
        metadata: {}
      )
      plan = Phronomy::Agent::ContextPlan.new(
        knowledge: [generated], conversation: [[item]]
      )

      expect { described_class.new.validate!(input: policy_input, plan: plan) }
        .to raise_error(ArgumentError, /duplicate item IDs/)
    end

    it "rejects omission of a required conversation group" do
      item = conversation_item(id: "required", kind: :external_message, sequence: 1, required: true)
      policy_input = empty_input(conversation: [[item]])

      expect {
        described_class.new.validate!(input: policy_input, plan: Phronomy::Agent::ContextPlan.new)
      }.to raise_error(Phronomy::ContextBudgetExceededError, /required conversation/)
    end
  end

  describe Phronomy::Agent::ContextPolicyInputBuilder do
    def candidate(id:, category:, sequence:, tool_call_id: nil, tool_call_ids: [])
      Phronomy::Agent::Selection::Candidate.new(
        candidate_id: id, source_kind: :working, category: category,
        role: ((category == :tool_message) ? :tool : :assistant),
        content_ref: "ref-#{id}", record_id: "record-#{id}", agent_id: "a",
        execution_id: "e", llm_call_id: "llm", tool_call_id: tool_call_id,
        sequence: sequence,
        constraint: Phronomy::Agent::Selection::Constraint.selectable(origin: :context_policy),
        priority: 0,
        metadata: {"estimated_tokens" => 5, "tool_call_ids" => tool_call_ids}
      )
    end

    it "groups an assistant Tool Call and Tool message atomically and marks latest current exchange required" do
      contents = {
        "ref-assistant" => Phronomy::CanonicalJSON.dump(
          "role" => "assistant", "content" => nil,
          "tool_calls" => [{"id" => "tc", "name" => "tool", "arguments" => {}}]
        ),
        "ref-tool" => Phronomy::CanonicalJSON.dump(
          "role" => "tool", "content" => "ok", "tool_call_id" => "tc"
        )
      }
      builder = described_class.new(content_loader: ->(ref) { contents.fetch(ref) })
      result = builder.build(
        agent_id: "a", execution_id: "e", call_sequence: 2, call_mode: :complete,
        candidates: [
          candidate(id: "assistant", category: :assistant_message, sequence: 1, tool_call_ids: ["tc"]),
          candidate(id: "tool", category: :tool_message, sequence: 2, tool_call_id: "tc")
        ],
        instruction: [], tools: [], current_input: nil, token_budget: nil,
        model_config: {}, previous_manifest: nil
      )

      expect(result.conversation.length).to eq(1)
      expect(result.conversation.first.map(&:id)).to eq(%w[assistant tool])
      expect(result.conversation.first).to all(be_required)
    end

    it "rejects an orphan Tool message" do
      contents = {
        "ref-tool" => Phronomy::CanonicalJSON.dump(
          "role" => "tool", "content" => "ok", "tool_call_id" => "tc"
        )
      }
      builder = described_class.new(content_loader: ->(ref) { contents.fetch(ref) })

      expect {
        builder.build(
          agent_id: "a", execution_id: "e", call_sequence: 2, call_mode: :complete,
          candidates: [candidate(id: "tool", category: :tool_message, sequence: 1, tool_call_id: "tc")],
          instruction: [], tools: [], current_input: nil, token_budget: nil,
          model_config: {}, previous_manifest: nil
        )
      }.to raise_error(ArgumentError, /orphan Tool message/)
    end
  end

  describe "ProviderCallOutcome.capture" do
    let(:outcome_class) { Phronomy::Agent::ProviderCallOutcome }
    let(:msg_struct) { Struct.new(:role, :content, :tool_calls, :tokens, :model_id) }
    let(:call_struct) { Struct.new(:id, :name, :arguments) }

    it "returns nil for nil message" do
      expect(outcome_class.capture(nil)).to be_nil
    end

    it "handles tool_calls as Array" do
      call = call_struct.new("c1", "tool", {})
      outcome = outcome_class.capture(msg_struct.new(:assistant, "hi", [call], nil, nil))
      expect(outcome.tool_calls.first["id"]).to eq("c1")
    end

    it "normalizes Symbol and nested Array values" do
      outcome = outcome_class.capture(msg_struct.new(:assistant, [:a, :b], nil, nil, nil))
      expect(outcome.content).to eq(["a", "b"])
    end

    it "uses to_h fallback for unknown content objects" do
      obj = Object.new
      def obj.to_h = {"x" => 1}
      outcome = outcome_class.capture(msg_struct.new(:assistant, obj, nil, nil, nil))
      expect(outcome.content).to eq("x" => 1)
    end

    it "captures model_id when present" do
      outcome = outcome_class.capture(msg_struct.new(:assistant, nil, nil, nil, "gpt-4"))
      expect(outcome.metadata["model_id"]).to eq("gpt-4")
    end
  end
end
