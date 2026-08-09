# frozen_string_literal: true

require "spec_helper"

# Branch coverage for Context Policy domain files.
RSpec.describe "Context Policy branch coverage" do
  let(:cand_class) { Phronomy::Agent::ContextCandidate }
  let(:unit_class) { Phronomy::Agent::ContextSelectionUnit }
  let(:plan_class) { Phronomy::Agent::ContextPlan }
  let(:validator) { Phronomy::Agent::ContextPlanValidator.new }
  let(:unit_builder) { Phronomy::Agent::ContextParts::UnitBuilders::DependencyAwareUnitBuilder.new }

  def make_candidate(id:, category:, sequence:, requirement: :optional, tool_call_id: nil,
    tool_call_ids: [], llm_call_id: nil, source_kind: :journal)
    role = (category == :tool_message) ? :tool : :assistant
    cand_class.new(
      candidate_id: id, source_kind: source_kind, category: category, role: role,
      content_ref: "ref-#{id}", record_id: "rec-#{id}", agent_id: "ag-1",
      execution_id: "ex-1", llm_call_id: llm_call_id, tool_call_id: tool_call_id,
      sequence: sequence, requirement: requirement, priority: 0,
      metadata: {
        "estimated_tokens" => 5,
        "source_sequence" => sequence,
        "tool_call_ids" => tool_call_ids
      }
    )
  end

  def make_unit(id:, candidate_ids:, requirement: :optional, seq: [0, 0])
    unit_class.new(
      unit_id: id, candidate_ids: candidate_ids, dependency_unit_ids: [],
      kind: :message, requirement: requirement, priority: 0,
      sequence_range: seq, metadata: {}
    )
  end

  def make_request(candidates, parts_override = {})
    default_parts = {
      unit_builder: unit_builder,
      required_context_resolver: Phronomy::Agent::ContextParts::Requirements::RequiredContextResolver.new,
      recent_first_selector: Phronomy::Agent::ContextParts::Selectors::RecentFirstSelector.new,
      token_budget_packer: Phronomy::Agent::ContextParts::Budget::TokenBudgetPacker.new
    }
    Phronomy::Agent::ContextRequest.new(
      agent_id: "ag-1", execution_id: "ex-1", call_sequence: 1,
      call_mode: :complete, candidates: candidates,
      token_budget: Phronomy::LlmContextWindow::TokenBudget.new(context_window: 500, max_output_tokens: 0),
      model_config: {}, previous_manifest: nil, required_coverage: [],
      parts: default_parts.merge(parts_override), metadata: {}
    )
  end

  describe "ContextPlanValidator" do
    it "raises when plan contains unknown unit IDs" do
      req = make_request([make_candidate(id: "a", category: :assistant_message, sequence: 1)])
      plan = plan_class.new(
        selected_unit_ids: ["nonexistent"],
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /unknown units/)
    end

    it "raises when plan omits a required unit" do
      req = make_request([
        make_candidate(id: "a", category: :assistant_message, sequence: 1, requirement: :protocol_required)
      ])
      plan = plan_class.new(
        selected_unit_ids: [],
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(Phronomy::ContextBudgetExceededError, /omitted required/)
    end

    it "raises on duplicate tool_message per tool_call_id" do
      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :tool_message, sequence: 2, tool_call_id: "tc1"),
        make_candidate(id: "c", category: :tool_message, sequence: 3, tool_call_id: "tc1")
      ]
      req = make_request(candidates)
      units = unit_builder.build(candidates)
      plan = plan_class.new(
        selected_unit_ids: units.map(&:unit_id),
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /duplicate Tool message/)
    end

    it "raises when assistant Tool Call is selected without its tool_message" do
      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :assistant_message, sequence: 2)
      ]
      req = make_request(candidates)
      units = unit_builder.build(candidates)
      plan = plan_class.new(
        selected_unit_ids: units.map(&:unit_id),
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /without a Tool message/)
    end

    it "raises when tool_message is selected without its assistant" do
      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :tool_message, sequence: 2, tool_call_id: "tc1")
      ]
      req = make_request(candidates)
      units = unit_builder.build(candidates)
      tool_unit = units.find { |u| u.candidate_ids == ["b"] }
      unless tool_unit
        plan = plan_class.new(
          selected_unit_ids: [],
          derived_contents: [], selected_tool_ids: [],
          ordering_hints: {}, policy_descriptor: nil, metadata: {}
        )
        expect { validator.validate!(request: req, plan: plan) }.not_to raise_error
        next
      end
      plan = plan_class.new(
        selected_unit_ids: [tool_unit.unit_id],
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /orphan Tool message/)
    end

    it "raises on derived content that is not DerivedContentSpec" do
      req = make_request([make_candidate(id: "a", category: :assistant_message, sequence: 1)])
      units = unit_builder.build(req.candidates)
      plan = plan_class.new(
        selected_unit_ids: units.map(&:unit_id),
        derived_contents: ["not_a_spec"],
        selected_tool_ids: [], ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /DerivedContentSpec/)
    end

    it "raises on derived content with unknown coverage candidates" do
      req = make_request([make_candidate(id: "a", category: :assistant_message, sequence: 1)])
      units = unit_builder.build(req.candidates)
      derived = Phronomy::Agent::DerivedContentSpec.new(
        content: "summary", content_format: :text, category: :assistant_message,
        role: :assistant, coverage_candidate_ids: ["nonexistent"],
        source_record_ids: [], source_content_refs: [],
        transformer_id: "t1", transformer_version: 1, metadata: {}
      )
      plan = plan_class.new(
        selected_unit_ids: units.map(&:unit_id),
        derived_contents: [derived],
        selected_tool_ids: [], ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { validator.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /unknown candidates/)
    end

    it "raises when plan is not a ContextPlan" do
      req = make_request([make_candidate(id: "a", category: :assistant_message, sequence: 1)])
      expect { validator.validate!(request: req, plan: "not_a_plan") }
        .to raise_error(ArgumentError, /expected.*ContextPlan/)
    end
  end

  describe "ProviderCallOutcome.capture" do
    let(:outcome_class) { Phronomy::Agent::ProviderCallOutcome }
    let(:msg_struct) { Struct.new(:role, :content, :tool_calls, :tokens, :model_id) }
    let(:call_struct) { Struct.new(:id, :name, :arguments) }
    let(:tokens_struct) { Struct.new(:input, :output) }

    it "returns nil for nil message" do
      expect(outcome_class.capture(nil)).to be_nil
    end

    it "handles tool_calls as Array (no .values)" do
      call = call_struct.new("c1", "tool", {})
      message = msg_struct.new(:assistant, "hi", [call], nil, nil)
      outcome = outcome_class.capture(message)
      expect(outcome.tool_calls).to be_an(Array)
      expect(outcome.tool_calls.first["id"]).to eq("c1")
    end

    it "handles tokens without to_h" do
      token_obj = Object.new
      def token_obj.to_s = "custom_tokens"
      message = msg_struct.new(:assistant, "hi", nil, token_obj, nil)
      outcome = outcome_class.capture(message)
      expect(outcome).not_to be_nil
    end

    it "normalizes Symbol values to strings" do
      message = msg_struct.new(:assistant, :symbolic_content, nil, nil, nil)
      outcome = outcome_class.capture(message)
      expect(outcome.content).to eq("symbolic_content")
    end

    it "normalizes nested Array values" do
      message = msg_struct.new(:assistant, [:a, :b], nil, nil, nil)
      outcome = outcome_class.capture(message)
      expect(outcome.content).to eq(["a", "b"])
    end

    it "uses to_h fallback for unknown objects in normalize" do
      obj = Object.new
      def obj.to_h = {"x" => 1}
      message = msg_struct.new(:assistant, obj, nil, nil, nil)
      outcome = outcome_class.capture(message)
      expect(outcome.content).to eq("x" => 1)
    end

    it "captures model_id when present" do
      message = msg_struct.new(:assistant, nil, nil, nil, "gpt-4")
      outcome = outcome_class.capture(message)
      expect(outcome.metadata["model_id"]).to eq("gpt-4")
    end

    it "handles tool_call without to_h by building hash from id/name/arguments" do
      call = Object.new
      def call.id = "c1"
      def call.name = "tool"
      def call.arguments = {}
      message = msg_struct.new(:assistant, nil, [call], nil, nil)
      outcome = outcome_class.capture(message)
      expect(outcome.tool_calls.first["id"]).to eq("c1")
    end
  end

  describe "DependencyAwareUnitBuilder" do
    it "resolves canonical tool exchange when entry is a tool_message" do
      candidates = [
        make_candidate(id: "asst", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "msg", category: :tool_message, sequence: 2, tool_call_id: "tc1")
      ]
      units = unit_builder.build(candidates)
      exchange = units.find { |u| u.kind == :tool_exchange }
      expect(exchange).not_to be_nil
      expect(exchange.candidate_ids).to include("asst", "msg")
    end

    it "returns nil from canonical_tool_exchange for assistant with no tool_call_ids" do
      candidates = [make_candidate(id: "a", category: :assistant_message, sequence: 1)]
      units = unit_builder.build(candidates)
      expect(units.first.kind).to eq(:message)
    end

    it "raises on duplicate assistant Tool Call id across two assistants" do
      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :assistant_message, sequence: 2, tool_call_ids: ["tc1"])
      ]
      expect { unit_builder.build(candidates) }
        .to raise_error(ArgumentError, /duplicate assistant Tool Call id/)
    end

    it "uses :declared_required requirement when no :protocol_required present" do
      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1,
          requirement: :declared_required, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :tool_message, sequence: 2,
          tool_call_id: "tc1", requirement: :declared_required)
      ]
      units = unit_builder.build(candidates)
      exchange = units.find { |u| u.kind == :tool_exchange }
      expect(exchange).not_to be_nil
      expect(exchange.requirement).to eq(:declared_required)
    end

    it "uses symbol key for tool_call_ids metadata" do
      candidate = cand_class.new(
        candidate_id: "a", source_kind: :journal, category: :assistant_message,
        role: :assistant, content_ref: "ref-a", record_id: "rec-a",
        agent_id: "ag-1", execution_id: "ex-1", llm_call_id: nil, tool_call_id: nil,
        sequence: 1, requirement: :optional, priority: 0,
        metadata: {:tool_call_ids => ["tc1"], "estimated_tokens" => 5, "source_sequence" => 1}
      )
      msg = make_candidate(id: "m", category: :tool_message, sequence: 2, tool_call_id: "tc1")
      units = unit_builder.build([candidate, msg])
      exchange = units.find { |u| u.kind == :tool_exchange }
      expect(exchange).not_to be_nil
    end
  end

  describe "ContextPolicies::Default" do
    it "returns a custom descriptor when config is not empty" do
      policy = Phronomy::Agent::ContextPolicies::Default.new("recency_limit" => 5)
      expect(policy.descriptor.config).to eq({"recency_limit" => 5})
    end
  end

  describe "ContextPolicyDescriptor" do
    let(:desc_class) { Phronomy::Agent::ContextPolicyDescriptor }

    it "raises on empty id" do
      expect { desc_class.new(id: "", version: 1) }
        .to raise_error(ArgumentError, /id must not be empty/)
    end

    it "raises on non-positive version" do
      expect { desc_class.new(id: "p1", version: 0) }
        .to raise_error(ArgumentError, /version must be positive/)
    end

    it "raises on config digest mismatch in from_h" do
      expect {
        desc_class.from_h({"id" => "p1", "version" => 1, "config" => {"a" => 1}, "config_digest" => "bad"})
      }.to raise_error(Phronomy::ConfigurationError, /digest mismatch/)
    end
  end

  describe "ContextPolicyRegistry" do
    let(:reg_class) { Phronomy::Agent::ContextPolicyRegistry }

    it "raises when registering without a factory block" do
      registry = reg_class.new
      expect { registry.register(id: "p1", version: 1) }
        .to raise_error(ArgumentError, /factory is required/)
    end

    it "raises on duplicate registration" do
      registry = reg_class.new
      registry.register(id: "p1", version: 1) { Phronomy::Agent::ContextPolicies::Default.new }
      expect { registry.register(id: "p1", version: 1) { nil } }
        .to raise_error(ArgumentError, /already registered/)
    end

    it "raises on resolving unknown policy" do
      registry = reg_class.new
      desc = Phronomy::Agent::ContextPolicyDescriptor.new(id: "unknown", version: 1)
      expect { registry.resolve(desc) }
        .to raise_error(Phronomy::ConfigurationError, /Unknown Context Policy/)
    end

    it "raises when factory returns wrong type" do
      registry = reg_class.new
      registry.register(id: "bad", version: 1) { "not_a_policy" }
      desc = Phronomy::Agent::ContextPolicyDescriptor.new(id: "bad", version: 1)
      expect { registry.resolve(desc) }
        .to raise_error(Phronomy::ConfigurationError, /expected.*ContextPolicy/)
    end
  end

  describe "ContextPlanValidator additional paths" do
    it "raises on duplicate assistant Tool Call id in candidates" do
      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :assistant_message, sequence: 2, tool_call_ids: ["tc1"])
      ]
      make_request(candidates)
      expect { unit_builder.build(candidates) }
        .to raise_error(ArgumentError, /duplicate assistant Tool Call id/)
    end

    it "raises on split assistant/Tool message dependency when tool_message is not in plan" do
      custom_builder = Class.new do
        def build(candidates)
          candidates.map.with_index do |c, i|
            Phronomy::Agent::ContextSelectionUnit.new(
              unit_id: "unit-#{c.candidate_id}",
              candidate_ids: [c.candidate_id],
              dependency_unit_ids: [],
              kind: :message, requirement: c.requirement,
              priority: 0, sequence_range: [i, i], metadata: {}
            )
          end
        end
      end.new

      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :tool_message, sequence: 2, tool_call_id: "tc1")
      ]
      req = make_request(candidates, unit_builder: custom_builder)
      units = custom_builder.build(candidates)
      asst_unit = units.find { |u| u.candidate_ids == ["a"] }
      plan = plan_class.new(
        selected_unit_ids: [asst_unit.unit_id],
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { Phronomy::Agent::ContextPlanValidator.new.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /split assistant\/Tool message dependency|without a Tool message/)
    end

    it "raises on orphan tool message selected without assistant" do
      custom_builder = Class.new do
        def build(candidates)
          candidates.map.with_index do |c, i|
            Phronomy::Agent::ContextSelectionUnit.new(
              unit_id: "unit-#{c.candidate_id}", candidate_ids: [c.candidate_id],
              dependency_unit_ids: [], kind: :message, requirement: c.requirement,
              priority: 0, sequence_range: [i, i], metadata: {}
            )
          end
        end
      end.new

      candidates = [
        make_candidate(id: "a", category: :assistant_message, sequence: 1, tool_call_ids: ["tc1"]),
        make_candidate(id: "b", category: :tool_message, sequence: 2, tool_call_id: "tc1")
      ]
      req = make_request(candidates, unit_builder: custom_builder)
      units = custom_builder.build(candidates)
      tool_unit = units.find { |u| u.candidate_ids == ["b"] }
      plan = plan_class.new(
        selected_unit_ids: [tool_unit.unit_id],
        derived_contents: [], selected_tool_ids: [],
        ordering_hints: {}, policy_descriptor: nil, metadata: {}
      )
      expect { Phronomy::Agent::ContextPlanValidator.new.validate!(request: req, plan: plan) }
        .to raise_error(ArgumentError, /orphan Tool message/)
    end
  end

  describe "ContextRequest with nil execution_id" do
    it "accepts nil execution_id (import records)" do
      req = Phronomy::Agent::ContextRequest.new(
        agent_id: "a", execution_id: nil, call_sequence: 1, call_mode: :complete,
        candidates: [],
        token_budget: Phronomy::LlmContextWindow::TokenBudget.new(context_window: 100, max_output_tokens: 0),
        model_config: {}, previous_manifest: nil, required_coverage: [], parts: {}, metadata: {}
      )
      expect(req.execution_id).to be_nil
    end
  end

  describe "DerivedContentSpec" do
    it "accepts nil role" do
      spec = Phronomy::Agent::DerivedContentSpec.new(
        content: "text", content_format: :text, category: :assistant_message,
        role: nil, coverage_candidate_ids: [],
        source_record_ids: [], source_content_refs: [],
        transformer_id: "t1", transformer_version: 1, metadata: {}
      )
      expect(spec.role).to be_nil
    end
  end

  describe "ActivationRegistry" do
    it "raises on duplicate execution_id registration" do
      registry = Phronomy::Agent::ActivationRegistry.new
      activation = double("Activation", execution_id: "exec-1")
      registry.register(activation)
      expect { registry.register(activation) }
        .to raise_error(ArgumentError, /already registered/)
    end
  end

  describe "ContextSelectionUnit" do
    it "raises on unknown requirement" do
      expect {
        Phronomy::Agent::ContextSelectionUnit.new(
          unit_id: "u1", candidate_ids: [], dependency_unit_ids: [],
          kind: :message, requirement: :invalid_req, priority: 0,
          sequence_range: [0, 1], metadata: {}
        )
      }.to raise_error(ArgumentError, /unknown ContextSelectionUnit requirement/)
    end

    it "raises when sequence_range does not have two integers" do
      expect {
        Phronomy::Agent::ContextSelectionUnit.new(
          unit_id: "u1", candidate_ids: [], dependency_unit_ids: [],
          kind: :message, requirement: :optional, priority: 0,
          sequence_range: [0], metadata: {}
        )
      }.to raise_error(ArgumentError, /sequence_range must contain two integers/)
    end
  end

  describe "TokenBudgetPacker" do
    let(:packer) { Phronomy::Agent::ContextParts::Budget::TokenBudgetPacker.new }

    def pack_request(units, context_window: 10, mandatory: 0)
      Phronomy::Agent::ContextRequest.new(
        agent_id: "a", execution_id: "e", call_sequence: 1, call_mode: :complete,
        candidates: units.flat_map(&:candidate_ids).map { |id|
          make_candidate(id: id, category: :assistant_message, sequence: 0)
        },
        token_budget: Phronomy::LlmContextWindow::TokenBudget.new(
          context_window: context_window, max_output_tokens: 0
        ),
        model_config: {}, previous_manifest: nil, required_coverage: [],
        parts: {}, metadata: {"mandatory_token_estimate" => mandatory}
      )
    end

    it "raises when mandatory exceeds budget" do
      unit = make_unit(id: "u1", candidate_ids: ["a"])
      req = pack_request([unit], context_window: 10, mandatory: 20)
      expect { packer.pack(request: req, units: [unit]) }
        .to raise_error(Phronomy::ContextBudgetExceededError, /Mandatory content/)
    end

    it "raises when required context exceeds remaining budget" do
      unit = make_unit(id: "u1", candidate_ids: ["a"], requirement: :protocol_required)
      req = pack_request([unit], context_window: 3, mandatory: 0)
      expect { packer.pack(request: req, units: [unit]) }
        .to raise_error(Phronomy::ContextBudgetExceededError, /Required Context/)
    end

    it "skips optional units that exceed remaining budget" do
      unit = make_unit(id: "u1", candidate_ids: ["a"], requirement: :optional)
      req = pack_request([unit], context_window: 3, mandatory: 0)
      result = packer.pack(request: req, units: [unit])
      expect(result).to be_empty
    end
  end

  describe "FinalBudgetValidator" do
    it "raises when canonical segment content exceeds budget" do
      manifest_segments = [
        {content_ref: "ref1", role: "user", position: 0}
      ]
      content_loader = ->(_ref) { "a" * 10_000 }
      validator_obj = Phronomy::Agent::ContextParts::Validators::FinalBudgetValidator.new(
        content_loader: content_loader
      )
      token_budget = Phronomy::LlmContextWindow::TokenBudget.new(context_window: 10, max_output_tokens: 0)
      expect {
        validator_obj.validate!(segments: manifest_segments, extra_values: [], token_budget: token_budget)
      }.to raise_error(Phronomy::ContextBudgetExceededError, /exceeds.*available/)
    end
  end
end
