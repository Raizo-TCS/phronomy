# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Orchestrator do
  # Stub agent that returns a fixed output string without calling a real LLM.
  def stub_agent(output_text)
    Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |_input, config: {}|
        {output: output_text, messages: []}
      end
    end
  end

  # Stub agent that captures what it was invoked with.
  def capturing_agent
    received = []
    agent_class = Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |input, config: {}|
        received << input
        {output: "echo:#{input}", messages: []}
      end
    end
    [agent_class, received]
  end

  describe "inheritance" do
    it "is a subclass of Phronomy::Agent::Base" do
      expect(described_class.ancestors).to include(Phronomy::Agent::Base)
    end
  end

  describe "#dispatch_parallel" do
    let(:orchestrator_class) do
      Class.new(described_class)
    end

    subject(:orchestrator) { orchestrator_class.new }

    it "returns results in the same order as the input tasks" do
      agent_a = stub_agent("result_a")
      agent_b = stub_agent("result_b")
      agent_c = stub_agent("result_c")

      results = orchestrator.dispatch_parallel(
        {agent: agent_a, input: "task a"},
        {agent: agent_b, input: "task b"},
        {agent: agent_c, input: "task c"}
      )

      expect(results.map { |r| r[:output] }).to eq(["result_a", "result_b", "result_c"])
    end

    it "forwards the :config hash to agent#invoke" do
      configs_received = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |input, config: {}|
          configs_received << config
          {output: "ok", messages: []}
        end
      end

      orchestrator.dispatch_parallel(
        {agent: agent_class, input: "task", config: {thread_id: "t1"}}
      )

      expect(configs_received.first).to eq({thread_id: "t1"})
    end

    it "uses an empty config hash when :config is omitted" do
      configs_received = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |input, config: {}|
          configs_received << config
          {output: "ok", messages: []}
        end
      end

      orchestrator.dispatch_parallel({agent: agent_class, input: "task"})

      expect(configs_received.first).to eq({})
    end

    it "re-raises exceptions from subagents" do
      failing_agent = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |_input, config: {}|
          raise "subagent exploded"
        end
      end

      expect {
        orchestrator.dispatch_parallel({agent: failing_agent, input: "test"})
      }.to raise_error(RuntimeError, "subagent exploded")
    end
  end

  describe "#fan_out" do
    let(:orchestrator_class) { Class.new(described_class) }
    subject(:orchestrator) { orchestrator_class.new }

    it "runs the same agent against every input and returns results in order" do
      agent_class, received = capturing_agent

      results = orchestrator.fan_out(agent: agent_class, inputs: %w[a b c])

      expect(received.sort).to eq(%w[a b c])
      expect(results.map { |r| r[:output] }.sort).to eq(%w[echo:a echo:b echo:c])
    end

    it "forwards config to every agent invocation" do
      configs_received = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) do |_input, config: {}|
          configs_received << config
          {output: "ok", messages: []}
        end
      end

      orchestrator.fan_out(agent: agent_class, inputs: %w[x y], config: {thread_id: "t2"})

      expect(configs_received).to all(eq({thread_id: "t2"}))
    end
  end

  describe ".subagent DSL" do
    let(:orchestrator_class) do
      agent_a = stub_agent("from_a")
      agent_b = stub_agent("from_b")

      Class.new(described_class) do
        subagent :researcher, agent_a
        subagent :analyst, agent_b
      end
    end

    it "registers both subagents in the class registry" do
      expect(orchestrator_class.registered_subagents.keys).to contain_exactly(:researcher, :analyst)
    end

    it "adds a tool for each declared subagent" do
      expect(orchestrator_class.tools.length).to eq(2)
    end

    it "names each tool dispatch_to_<name>" do
      tool_names = orchestrator_class.tools.map(&:tool_name)
      expect(tool_names).to contain_exactly("dispatch_to_researcher", "dispatch_to_analyst")
    end

    it "each generated tool executes the corresponding subagent" do
      tool_class = orchestrator_class.tools.find { |t| t.tool_name == "dispatch_to_researcher" }
      result = tool_class.new.execute(input: "what happened?")
      expect(result).to eq("from_a")
    end

    it "does not share the tool list with a sibling subclass" do
      sibling = Class.new(described_class) do
        subagent :helper, Class.new(Phronomy::Agent::Base) {
          define_method(:invoke) { |*| {output: "help", messages: []} }
        }
      end

      # sibling has 1 tool; orchestrator_class has 2 tools — they must not bleed
      expect(sibling.tools.length).to eq(1)
      expect(orchestrator_class.tools.length).to eq(2)
    end
  end

  describe ".subagent on_error:" do
    context "when :raise (default)" do
      let(:orchestrator_class) do
        failing = Class.new(Phronomy::Agent::Base) do
          define_method(:invoke) { |*| raise "boom" }
        end

        Class.new(described_class) do
          subagent :failing_worker, failing
        end
      end

      it "re-raises the exception from the generated tool" do
        tool_class = orchestrator_class.tools.first
        expect { tool_class.new.execute(input: "go") }.to raise_error(RuntimeError, "boom")
      end
    end

    context "when :skip" do
      let(:orchestrator_class) do
        failing = Class.new(Phronomy::Agent::Base) do
          define_method(:invoke) { |*| raise "boom" }
        end

        Class.new(described_class) do
          subagent :failing_worker, failing, on_error: :skip
        end
      end

      it "returns nil from the generated tool instead of raising" do
        tool_class = orchestrator_class.tools.first
        expect(tool_class.new.execute(input: "go")).to be_nil
      end
    end
  end

  describe ".registered_subagents" do
    it "is isolated per subclass (not shared via inheritance)" do
      base_class = Class.new(described_class) do
        subagent :base_worker, Class.new(Phronomy::Agent::Base) {
          define_method(:invoke) { |*| {output: "base", messages: []} }
        }
      end

      child_class = Class.new(base_class)

      expect(base_class.registered_subagents.keys).to include(:base_worker)
      expect(child_class.registered_subagents).to be_empty
    end
  end
end
