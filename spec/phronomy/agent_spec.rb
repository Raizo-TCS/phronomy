# frozen_string_literal: true

require "spec_helper"

# --- Agent classes for testing ---
class BasicAgent < Phronomy::Agent::Base
  agent_definition id: "basic-agent", version: 1
  model "test-model"
  instructions "You are a test assistant."
  temperature 0.5
  max_iterations 3
end

class InstructionProcAgent < Phronomy::Agent::Base
  agent_definition id: "instruction-proc-agent", version: 1
  instructions(->(input) { "Context: #{input[:context]}" })
end

class NoModelAgent < Phronomy::Agent::Base
  agent_definition id: "no-model-agent", version: 1
end

class DefaultDefinitionAgent < Phronomy::Agent::Base
  agent_definition version: 1
end

RSpec.describe Phronomy::Agent::Base do
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0, to_h: {"input" => 10, "output" => 5, "cached" => 0, "cache_creation" => 0}) }
  let(:fake_message) { double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }
  let(:fake_messages) { [fake_message] }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:before_tool_call)
    allow(dbl).to receive(:on_tool_result)
    allow(dbl).to receive(:ask).and_return(fake_message)
    allow(dbl).to receive(:messages).and_return(fake_messages)
    allow(dbl).to receive(:last_message).and_return(fake_message)
    dbl
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(fake_chat)
  end

  describe "class-level DSL" do
    it "returns the model" do
      expect(BasicAgent.model).to eq("test-model")
    end

    it "returns the instructions" do
      expect(BasicAgent.instructions).to eq("You are a test assistant.")
    end

    it "returns the temperature" do
      expect(BasicAgent.temperature).to eq(0.5)
    end

    it "returns max_iterations" do
      expect(BasicAgent.max_iterations).to eq(3)
    end

    it "uses the named class as the default Agent definition lineage" do
      expect(DefaultDefinitionAgent.agent_definition).to eq(
        id: "DefaultDefinitionAgent",
        version: 1
      )
    end

    it "defaults tools to an empty array" do
      expect(BasicAgent.tools).to eq([])
    end

    it "defaults max_iterations to 10" do
      expect(NoModelAgent.max_iterations).to eq(10)
    end

    it "falls back to configuration.default_model when model is not set" do
      Phronomy.configure { |c| c.default_model = "fallback-model" }
      expect(NoModelAgent.model).to eq("fallback-model")
      Phronomy.reset_configuration!
    end

    describe "DSL inheritance via Class.new (anonymous subclass)" do
      let(:tool_a) {
        Class.new(Phronomy::Agent::Context::Capability::Base) {
          tool_name "tool_a"
          def execute = "a"
        }
      }

      let(:parent) do
        t = tool_a
        Class.new(Phronomy::Agent::Base) do
          agent_definition id: "test-agent-76", version: 1
          model "parent-model"
          provider :openai
          instructions "Parent instructions."
          tools t => nil
        end
      end

      it "inherits instructions when subclass does not override" do
        child = Class.new(parent)
        expect(child.instructions).to eq("Parent instructions.")
      end

      it "inherits provider when subclass does not override" do
        child = Class.new(parent)
        expect(child.provider).to eq(:openai)
      end

      it "inherits tools when subclass does not override" do
        child = Class.new(parent)
        expect(child.tools).to eq(parent.tools)
      end

      it "uses the subclass instructions when explicitly overridden" do
        child = Class.new(parent) { instructions "Child instructions." }
        expect(child.instructions).to eq("Child instructions.")
        expect(parent.instructions).to eq("Parent instructions.")
      end

      it "uses the subclass provider when explicitly overridden" do
        child = Class.new(parent) { provider :anthropic }
        expect(child.provider).to eq(:anthropic)
        expect(parent.provider).to eq(:openai)
      end

      it "uses the subclass tools when explicitly overridden" do
        tool_b = Class.new(Phronomy::Agent::Context::Capability::Base) {
          tool_name "tool_b"
          def execute = "b"
        }
        child = Class.new(parent) { tools tool_b => nil }
        expect(child.tools).to eq([tool_b])
        expect(parent.tools).to eq([tool_a])
      end

      it "returns nil instructions at the Base level (terminates chain)" do
        expect(Phronomy::Agent::Base.instructions).to be_nil
      end
    end
  end

  describe "#invoke" do
    subject(:agent) { BasicAgent.new }

    it "passes String input to ask" do
      agent.invoke("Hello")
      expect(fake_chat).to have_received(:ask).with("Hello")
    end

    it "passes Hash input :message key to ask" do
      agent.invoke({message: "Hi there"})
      expect(fake_chat).to have_received(:ask).with("Hi there")
    end

    it "passes Hash input :query key to ask" do
      agent.invoke({query: "Search this"})
      expect(fake_chat).to have_received(:ask).with("Search this")
    end

    it "passes String instructions to with_instructions" do
      agent.invoke("Hello")
      expect(fake_chat).to have_received(:with_instructions).with("You are a test assistant.")
    end

    it "calls Proc instructions" do
      proc_agent = InstructionProcAgent.new
      proc_agent.invoke({context: "testing"})
      expect(fake_chat).to have_received(:with_instructions).with("Context: testing")
    end

    it "returns { output:, messages: }" do
      result = agent.invoke("Hello")
      expect(result).to include(:output, :messages, :usage)
      expect(result[:output]).to eq("LLM response")
    end

    it "returns a TokenUsage as :usage" do
      result = agent.invoke("Hello")
      expect(result[:usage]).to be_a(Phronomy::TokenUsage)
      expect(result[:usage].input).to eq(10)
      expect(result[:usage].output).to eq(5)
    end

    it "passes model to RubyLLM.chat" do
      agent.invoke("Hello")
      expect(RubyLLM).to have_received(:chat).with(hash_including(model: "test-model"))
    end

    it "passes temperature to chat via with_temperature" do
      agent.invoke("Hello")
      expect(fake_chat).to have_received(:with_temperature).with(0.5)
    end

    it "calls chat with no args when model is unset and default_model is nil" do
      NoModelAgent.new.invoke("Hello")
      expect(RubyLLM).to have_received(:chat).with(no_args)
    end

    it "works as a Runnable (batch)" do
      results = agent.batch(["Q1", "Q2"])
      expect(results.size).to eq(2)
    end

    context "stateful conversation (Agent Journal)" do
      it "accumulates conversation in the Agent Journal after each invoke" do
        agent.invoke("Hello")
        expect(agent.agent_root.journal_position).to be > 0
      end

      it "rejects the removed generic thread_id keyword" do
        expect {
          agent.invoke("Hello", thread_id: "t1")
        }.to raise_error(ArgumentError, /thread_id/)
      end
    end

    context "when model is resolvable and a token budget is available" do
      let(:mock_model) do
        double("RubyLLMModel", context_window: 16_000, max_output_tokens: 2_000)
      end

      before do
        allow(RubyLLM.models).to receive(:find).with("test-model").and_return(mock_model)
      end

      it "records conversation in the Agent Journal" do
        agent.invoke("Hello")
        expect(agent.agent_root.journal_position).to be > 0
      end
    end
  end
end

RSpec.describe "Phronomy::Agent::Base .tools with aliases" do
  let(:alias_tokens) { double("Tokens", input: 5, output: 2, cached: 0, cache_creation: 0, to_h: {"input" => 5, "output" => 2, "cached" => 0, "cache_creation" => 0}) }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:before_tool_call)
    allow(dbl).to receive(:on_tool_result)
    allow(dbl).to receive(:ask).and_return(double("Msg", content: "ok", tool_calls: nil, tokens: alias_tokens, tool_call?: false))
    allow(dbl).to receive(:messages).and_return([])
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

  let(:tool_a) do
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      description "Tool A"
      def execute = "a"
    end
  end

  let(:tool_b) do
    Class.new(Phronomy::Agent::Context::Capability::Base) do
      tool_name "tool_b"
      description "Tool B"
      def execute = "b"
    end
  end

  describe ".tools (hash form with aliases)" do
    it "stores the tool classes" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-81", version: 1
        model "m"
      end
      agent_class.tools(tool_a => "alpha", tool_b => "beta")
      expect(agent_class.tools).to eq([tool_a, tool_b])
    end

    it "stores the aliases" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-82", version: 1
        model "m"
      end
      agent_class.tools(tool_a => "alpha", tool_b => nil)
      expect(agent_class.tool_aliases).to eq({tool_a => "alpha"})
    end

    it "registers tools with aliased anonymous subclasses when an alias is given" do
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-83", version: 1
        model "m"
      end
      agent_class.tools(tool_a => "alpha", tool_b => nil)
      agent_class.new.invoke("hello")
      expect(fake_chat).to have_received(:with_tool).twice
      aliased = Class.new(tool_a) { tool_name "alpha" }
      expect(aliased.new.name).to eq("alpha")
    end

    it "nil alias leaves the original tool_name intact" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "original_name"
        def execute = ""
      end
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-84", version: 1
        model "m"
      end
      agent_class.tools(klass => nil)
      expect(agent_class.tool_aliases[klass]).to be_nil
      expect(klass.new.name).to eq("original_name")
    end
  end
end

# Regression tests for GitHub Issue #30 (ID-12):
# The temperature DSL uses `if val` to guard the assignment, which was reported
# to fail silently for temperature(0). In Ruby, 0 and 0.0 are truthy, so this
# code is actually correct. These specs document and lock in the correct behavior.
RSpec.describe "Phronomy::Agent::Base temperature DSL zero value (Issue #30 / ID-12)" do
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0, to_h: {"input" => 10, "output" => 5, "cached" => 0, "cache_creation" => 0}) }
  let(:fake_message) { double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }
  let(:fake_messages) { [fake_message] }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:before_tool_call)
    allow(dbl).to receive(:on_tool_result)
    allow(dbl).to receive(:ask).and_return(fake_message)
    allow(dbl).to receive(:messages).and_return(fake_messages)
    allow(dbl).to receive(:last_message).and_return(fake_message)
    dbl
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(fake_chat)
  end

  it "stores 0 correctly via the temperature DSL (0 is truthy in Ruby)" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-85", version: 1
      model "test-model"
      temperature 0
    end
    expect(klass.temperature).to eq(0)
  end

  it "stores 0.0 correctly via the temperature DSL" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-86", version: 1
      model "test-model"
      temperature 0.0
    end
    expect(klass.temperature).to eq(0.0)
  end

  it "calls with_temperature(0) on the chat object when temperature is 0" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-87", version: 1
      model "test-model"
      temperature 0
    end
    klass.new.invoke("Hello")
    expect(fake_chat).to have_received(:with_temperature).with(0)
  end
end

RSpec.describe "Phronomy::Agent::Base tool_aliases inheritance (Issue #126)" do
  let(:tool_a) { Class.new(Phronomy::Agent::Context::Capability::Base) { description "a" } }
  let(:tool_b) { Class.new(Phronomy::Agent::Context::Capability::Base) { description "b" } }

  it "returns an empty hash when no aliases are defined" do
    klass = Class.new(Phronomy::Agent::Base)
    expect(klass.tool_aliases).to eq({})
  end

  it "inherits parent aliases in a subclass" do
    parent = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-88", version: 1
    end
    parent.instance_variable_set(:@tool_aliases, {"ToolA" => "search"})

    child = Class.new(parent)
    expect(child.tool_aliases).to include("ToolA" => "search")
  end

  it "subclass-specific aliases take precedence over parent aliases" do
    parent = Class.new(Phronomy::Agent::Base)
    parent.instance_variable_set(:@tool_aliases, {"ToolA" => "parent_name"})

    child = Class.new(parent)
    child.instance_variable_set(:@tool_aliases, {"ToolA" => "child_name"})

    expect(child.tool_aliases["ToolA"]).to eq("child_name")
    expect(parent.tool_aliases["ToolA"]).to eq("parent_name")
  end

  it "child aliases do not leak into the parent" do
    parent = Class.new(Phronomy::Agent::Base)
    child = Class.new(parent)
    child.instance_variable_set(:@tool_aliases, {"ToolB" => "something"})

    expect(parent.tool_aliases.key?("ToolB")).to be false
  end
end
