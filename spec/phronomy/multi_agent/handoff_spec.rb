# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::Handoff do
  let(:target_klass) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-117", version: 1
      def self.name
        "Phronomy::Agent::BillingAgent"
      end
    end
  end

  let(:target_agent) { target_klass.new }
  subject(:handoff) { described_class.new(target_agent: target_agent) }

  describe "#initialize" do
    it "stores the target agent" do
      expect(handoff.target_agent).to equal(target_agent)
    end

    it "derives tool_name from the last segment of the class name" do
      expect(handoff.tool_name).to match(/\Atransfer_to_billing_agent_[0-9a-f]{8}\z/)
    end

    it "generates a default description" do
      expect(handoff.description).to include("BillingAgent")
    end

    it "accepts an explicit description" do
      h = described_class.new(target_agent: target_agent, description: "Go to billing")
      expect(h.description).to eq("Go to billing")
    end
  end

  describe "#sentinel" do
    it "starts with the SENTINEL_PREFIX" do
      expect(handoff.sentinel).to start_with(Phronomy::MultiAgent::Handoff::SENTINEL_PREFIX)
    end

    it "embeds the target agent class name" do
      expect(handoff.sentinel).to include("Phronomy::Agent::BillingAgent")
    end
  end

  describe "#to_tool_class" do
    subject(:tool_class) { handoff.to_tool_class }

    it "returns a subclass of Phronomy::Agent::Context::Capability::Base" do
      expect(tool_class.ancestors).to include(Phronomy::Agent::Context::Capability::Base)
    end

    it "sets the tool_name on the returned class" do
      expect(tool_class.tool_name).to match(/\Atransfer_to_billing_agent_[0-9a-f]{8}\z/)
    end

    it "executes and returns the sentinel string" do
      tool_instance = tool_class.new
      expect(tool_instance.execute).to eq(handoff.sentinel)
    end
  end

  # Regression test for issue #41:
  # Two Handoff instances targeting the same agent class must have distinct
  # tool_names so the LLM can address each target independently.
  describe "tool_name uniqueness across instances (issue #41)" do
    it "assigns different tool_names to two Handoffs for the same class" do
      agent_a = target_klass.new
      agent_b = target_klass.new

      handoff_a = described_class.new(target_agent: agent_a)
      handoff_b = described_class.new(target_agent: agent_b)

      expect(handoff_a.tool_name).not_to eq(handoff_b.tool_name)
    end

    it "assigns different tool_names even when two classes share the same simple name" do
      # Simulate Accounts::BillingAgent vs Payments::BillingAgent — both
      # have the same last segment "BillingAgent".
      klass_accounts = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-118", version: 1
        def self.name = "Accounts::BillingAgent"
      end
      klass_payments = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-119", version: 1
        def self.name = "Payments::BillingAgent"
      end

      h1 = described_class.new(target_agent: klass_accounts.new)
      h2 = described_class.new(target_agent: klass_payments.new)

      expect(h1.tool_name).not_to eq(h2.tool_name)
    end
  end
end

RSpec.describe Phronomy::Agent::Runner do
  let(:entry_klass) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-120", version: 1
      model "stub-model"
      provider :openai
      instructions "Entry agent."
    end
  end

  let(:target_klass) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-121", version: 1
      model "stub-model"
      provider :openai
      instructions "Target agent."
    end
  end

  let(:entry) { entry_klass.new }
  let(:target) { target_klass.new }

  describe "#initialize" do
    it "raises ArgumentError when agents is empty" do
      expect { described_class.new(agents: []) }.to raise_error(ArgumentError, /at least one agent/i)
    end

    it "stores the agents array" do
      runner = described_class.new(agents: [entry])
      expect(runner.agents).to eq([entry])
    end

    it "registers handoff tools on the source agent" do
      described_class.new(agents: [entry, target], routes: {entry => [target]})
      expect(entry._handoff_tools.size).to eq(1)
    end
  end

  describe "#invoke" do
    let(:ok_result) { {output: "OK", messages: [], usage: Phronomy::TokenUsage.zero} }

    context "when no handoff is triggered" do
      it "returns the entry agent result with :agent key" do
        allow(entry).to receive(:invoke).and_return(ok_result)
        runner = described_class.new(agents: [entry])
        result = runner.invoke("hello")
        expect(result[:agent]).to equal(entry)
        expect(result[:output]).to eq("OK")
      end
    end

    context "when a handoff is triggered once" do
      it "routes to the target agent and returns its result" do
        runner = described_class.new(agents: [entry, target], routes: {entry => [target]})
        sentinel = runner.instance_variable_get(:@sentinel_map).keys.first
        tool_msg = double("tool_msg", role: :tool, content: sentinel)

        entry_result = {output: "Transferring.", messages: [tool_msg], usage: Phronomy::TokenUsage.zero}
        target_result = {output: "I can help.", messages: [], usage: Phronomy::TokenUsage.zero}

        allow(entry).to receive(:invoke).and_return(entry_result)
        allow(target).to receive(:invoke).and_return(target_result)

        result = runner.invoke("I need help.")
        expect(result[:agent]).to equal(target)
        expect(result[:output]).to eq("I can help.")
      end
    end

    context "when MAX_HANDOFFS is exceeded" do
      it "raises Phronomy::HandoffError" do
        runner = described_class.new(
          agents: [entry, target],
          routes: {entry => [target], target => [entry]}
        )
        sentinel_map = runner.instance_variable_get(:@sentinel_map)
        sentinel1 = sentinel_map.keys.find { |k| k.include?(target_klass.name.to_s.split("::").last.to_s) } ||
          sentinel_map.keys.first
        sentinel2 = sentinel_map.keys.find { |k| k.include?(entry_klass.name.to_s.split("::").last.to_s) } ||
          sentinel_map.keys.last

        msg1 = double("msg1", role: :tool, content: sentinel1)
        msg2 = double("msg2", role: :tool, content: sentinel2)

        allow(entry).to receive(:invoke).and_return(
          {output: "x", messages: [msg1], usage: Phronomy::TokenUsage.zero}
        )
        allow(target).to receive(:invoke).and_return(
          {output: "y", messages: [msg2], usage: Phronomy::TokenUsage.zero}
        )

        stub_const("Phronomy::Agent::Runner::MAX_HANDOFFS", 1)
        expect { runner.invoke("ping") }.to raise_error(Phronomy::HandoffError, /exceeded/i)
      end
    end
  end
end

RSpec.describe "Phronomy::MultiAgent::Handoff sentinel uniqueness" do
  let(:target) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-122", version: 1
      model "stub-model"
      provider :openai
    end.new
  end

  it "generates a different sentinel for each Handoff instance pointing at the same target" do
    h1 = Phronomy::MultiAgent::Handoff.new(target_agent: target)
    h2 = Phronomy::MultiAgent::Handoff.new(target_agent: target)
    expect(h1.sentinel).not_to eq(h2.sentinel)
  end

  it "includes the target class name in the sentinel" do
    handoff = Phronomy::MultiAgent::Handoff.new(target_agent: target)
    expect(handoff.sentinel).to include(target.class.name.to_s)
  end
end

RSpec.describe "Phronomy::Agent::Base#_add_handoff_tool" do
  let(:klass) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-123", version: 1
      model "stub-model"
      provider :openai
    end
  end

  subject(:agent) { klass.new }

  it "returns self for method chaining" do
    tool_class = Class.new(Phronomy::Agent::Context::Capability::Base)
    expect(agent._add_handoff_tool(tool_class)).to equal(agent)
  end

  it "accumulates multiple handoff tools" do
    t1 = Class.new(Phronomy::Agent::Context::Capability::Base)
    t2 = Class.new(Phronomy::Agent::Context::Capability::Base)
    agent._add_handoff_tool(t1)
    agent._add_handoff_tool(t2)
    expect(agent._handoff_tools).to contain_exactly(t1, t2)
  end

  it "returns empty array by default" do
    expect(agent._handoff_tools).to eq([])
  end
end
