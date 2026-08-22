# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::HandoffPolicy do
  it "defines the four initial Handoff policy categories" do
    expect(described_class::CATEGORIES).to eq(
      %i[current_request history knowledge tool_exchanges]
    )
  end

  it "builds required, forbidden and selectable rules" do
    policy = described_class.define do
      required :current_request
      selectable :history, default: :include
      forbidden :knowledge
      selectable :tool_exchanges, default: :exclude
    end

    expect(policy.required?(:current_request)).to be(true)
    expect(policy.default_include?(:history)).to be(true)
    expect(policy.forbidden?(:knowledge)).to be(true)
    expect(policy.default_include?(:tool_exchanges)).to be(false)
  end

  it "requires all initial categories to be declared" do
    expect do
      described_class.define do
        required :current_request
      end
    end.to raise_error(ArgumentError, /missing/)
  end

  it "rejects unknown categories" do
    expect do
      described_class.define do
        required :current_request
        selectable :history
        selectable :knowledge
        selectable :tool_exchanges
        selectable :unknown_category
      end
    end.to raise_error(ArgumentError, /unknown Handoff policy category/)
  end

  it "rejects invalid selectable defaults" do
    expect do
      described_class.define do
        required :current_request
        selectable :history, default: :sometimes
        selectable :knowledge
        selectable :tool_exchanges
      end
    end.to raise_error(ArgumentError, /selectable default/)
  end

  it "uses the conservative default for persistent Knowledge" do
    policy = described_class.default
    expect(policy.required?(:current_request)).to be(true)
    expect(policy.default_include?(:history)).to be(true)
    expect(policy.selectable?(:knowledge)).to be(true)
    expect(policy.default_include?(:knowledge)).to be(false)
    expect(policy.default_include?(:tool_exchanges)).to be(true)
  end

  it "is immutable after construction" do
    policy = described_class.default
    expect(policy).to be_frozen
    expect(policy.to_h).to be_frozen
  end
end

RSpec.describe Phronomy::MultiAgent::Handoff do
  let(:source_klass) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-source", version: 1
      model "stub-model"
    end
  end

  let(:target_klass) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-target", version: 1
      model "stub-model"
    end
  end

  let(:source) { source_klass.new }
  let(:target) { target_klass.new }

  subject(:handoff) do
    described_class.new(
      source_agent: source,
      target_agent: target,
      description: "Transfer billing responsibility"
    )
  end

  it "represents one explicit Source to Target edge" do
    expect(handoff.source_agent).to equal(source)
    expect(handoff.target_agent).to equal(target)
    expect(handoff.policy).to equal(Phronomy::MultiAgent::HandoffPolicy.default)
    expect(handoff.description).to eq("Transfer billing responsibility")
  end

  it "does not expose routing encoding as public Handoff semantics" do
    expect(handoff).not_to respond_to(:tool_name)
    expect(handoff).not_to respond_to(:sentinel)
    expect(handoff).not_to respond_to(:to_tool_class)
    expect(described_class.const_defined?(:SENTINEL_PREFIX, false)).to be(false)
  end

  it "rejects a self-Handoff" do
    expect do
      described_class.new(source_agent: source, target_agent: source)
    end.to raise_error(ArgumentError, /must be different instances/)
  end
end

RSpec.describe Phronomy::MultiAgent::HandoffCapabilityFactory do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-capability-agent", version: 1
      model "stub-model"
    end
  end

  it "creates a cooperative private capability without making its Tool name the Handoff identity" do
    source = agent_class.new
    target = agent_class.new
    edge = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target
    )

    binding = described_class.build(edge)
    expect(binding.handoff).to equal(edge)
    expect(binding.tool_class.execution_mode).to eq(:cooperative)
    expect(described_class.lookup(binding.tool_name)).to equal(binding)
    expect(edge).not_to respond_to(:tool_name)
  end
end

RSpec.describe Phronomy::Agent::AgentInvocation do
  ToolCall = Struct.new(:id, :name, :arguments)

  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-invocation-agent", version: 1
      model "stub-model"
    end
  end

  def build_binding(source, target)
    edge = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: Phronomy::MultiAgent::HandoffPolicy.define do
        required :current_request
        selectable :history, default: :include
        selectable :knowledge, default: :exclude
        selectable :tool_exchanges, default: :include
      end
    )
    Phronomy::MultiAgent::HandoffCapabilityFactory.build(edge)
  end

  it "turns one intercepted Handoff capability into a typed HandoffRequest" do
    source = agent_class.new
    target = agent_class.new
    binding = build_binding(source, target)
    invocation = described_class.new(
      agent: source,
      input: "hello",
      config: {phronomy_handoff_bindings: [binding]}
    )

    invocation.accept_tool_calls!([
      ToolCall.new(
        "call-1",
        binding.tool_name,
        {"responsibility" => "Continue the billing investigation", "include_history" => false}
      )
    ], llm_call_id: "llm-1")

    expect(invocation.handoff_requested?).to be(true)
    expect(invocation.pending_tool_calls).to be_empty
    expect(invocation.handoff_request.handoff).to equal(binding.handoff)
    expect(invocation.handoff_request.responsibility).to eq("Continue the billing investigation")
    expect(invocation.handoff_request.selection_intent[:history]).to be(false)
  end

  it "rejects a Handoff mixed with an ordinary Tool Call" do
    source = agent_class.new
    target = agent_class.new
    binding = build_binding(source, target)
    invocation = described_class.new(
      agent: source,
      input: "hello",
      config: {phronomy_handoff_bindings: [binding]}
    )

    invocation.accept_tool_calls!([
      ToolCall.new("handoff", binding.tool_name, {"responsibility" => "Continue"}),
      ToolCall.new("normal", "ordinary_tool", {})
    ], llm_call_id: "llm-1")

    expect(invocation.handoff_requested?).to be(false)
    expect(invocation.handoff_failed?).to be(true)
    expect(invocation.error).to be_a(Phronomy::HandoffError)
  end

  it "rejects multiple Handoffs in one Provider outcome" do
    source = agent_class.new
    first_target = agent_class.new
    second_target = agent_class.new
    first = build_binding(source, first_target)
    second = build_binding(source, second_target)
    invocation = described_class.new(
      agent: source,
      input: "hello",
      config: {phronomy_handoff_bindings: [first, second]}
    )

    invocation.accept_tool_calls!([
      ToolCall.new("handoff-1", first.tool_name, {"responsibility" => "First"}),
      ToolCall.new("handoff-2", second.tool_name, {"responsibility" => "Second"})
    ], llm_call_id: "llm-1")

    expect(invocation.handoff_requested?).to be(false)
    expect(invocation.handoff_failed?).to be(true)
    expect(invocation.error).to be_a(Phronomy::HandoffError)
    expect(invocation.error.message).to match(/multiple Handoffs|mix Handoff/)
  end
end

RSpec.describe Phronomy::MultiAgent::Coordinator do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "handoff-coordination-agent", version: 1
      model "stub-model"
    end
  end

  it "rejects duplicate Source to Target edges" do
    source = agent_class.new
    target = agent_class.new
    first = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    second = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)

    expect do
      described_class.new(main_agent: source, handoffs: [first, second])
    end.to raise_error(ArgumentError, /duplicate/)
  end

  it "starts a new coordination lifetime at the main Agent" do
    source = agent_class.new
    target = agent_class.new
    edge = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    coordinator = described_class.new(main_agent: source, handoffs: [edge])

    expect(coordinator.snapshot.active_agent).to equal(source)
    expect(coordinator.snapshot.active_handoff_context).to be_nil
  end

  it "rejects an incompatible recreated Runner graph for the same main Agent" do
    source = agent_class.new
    first_target = agent_class.new
    second_target = agent_class.new
    first = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: first_target)
    second = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: second_target)

    described_class.attach(main_agent: source, handoffs: [first])

    expect do
      described_class.attach(main_agent: source, handoffs: [second])
    end.to raise_error(Phronomy::ConfigurationError, /different Handoff graph/)
  end

  it "admits only one active Multi-Agent turn for one coordination lifetime" do
    source = agent_class.new
    target = agent_class.new
    edge = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    coordinator = described_class.attach(main_agent: source, handoffs: [edge])
    runtime = Phronomy::Runtime.instance

    runtime.__admit_multi_agent(coordinator)
    begin
      expect do
        runtime.__admit_multi_agent(coordinator)
      end.to raise_error(Phronomy::HandoffError, /already active/)
    ensure
      runtime.__release_multi_agent(coordinator)
    end
  end

  it "does not carry active-Agent continuation across a Runtime reset" do
    source = agent_class.new
    target = agent_class.new
    edge = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
    coordinator = described_class.attach(main_agent: source, handoffs: [edge])
    request = Phronomy::MultiAgent::HandoffRequest.new(
      handoff: edge,
      responsibility: "Continue elsewhere",
      selection_intent: {}
    )
    context = Phronomy::MultiAgent::HandoffContext.new(
      responsibility: "Continue elsewhere"
    )

    coordinator.transition!(request, context)
    expect(coordinator.snapshot.active_agent).to equal(target)

    Phronomy.reset_runtime!

    recreated = described_class.attach(main_agent: source, handoffs: [edge])
    expect(recreated.snapshot.active_agent).to equal(source)
    expect(recreated.snapshot.active_handoff_context).to be_nil
  end
end
