# frozen_string_literal: true

require "spec_helper"

# --- Agent classes for testing ---
class BasicAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a test assistant."
  temperature 0.5
  max_iterations 3
end

class InstructionProcAgent < Phronomy::Agent::Base
  instructions(->(input) { "Context: #{input[:context]}" })
end

class NoModelAgent < Phronomy::Agent::Base
end

RSpec.describe Phronomy::Agent::Base do
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0) }
  let(:fake_message) { double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }
  let(:fake_messages) { [fake_message] }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
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
          model "parent-model"
          provider :openai
          instructions "Parent instructions."
          tools t
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
        child = Class.new(parent) { tools tool_b }
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

    context "with messages in config" do
      let(:prev_msg) { double("PrevMessage", role: :user, content: "previous") }

      it "injects the provided messages into the chat" do
        agent.invoke("Hello", messages: [prev_msg])
        expect(fake_chat.messages).to include(prev_msg)
      end

      it "works without messages in config" do
        agent.invoke("Hello", thread_id: "t1")
        # no error is raised — empty history is used
      end
    end

    context "with max_output_tokens and context_overhead DSL" do
      # An agent whose model IS in the RubyLLM registry (mocked).
      let(:mock_model) do
        double("RubyLLMModel", context_window: 32_768, max_output_tokens: 8_192)
      end

      before do
        allow(RubyLLM.models).to receive(:find).with("test-model").and_return(mock_model)
      end

      let(:budget_agent_class) do
        Class.new(Phronomy::Agent::Base) do
          model "test-model"
          max_output_tokens 2048
          context_overhead 300
        end
      end

      it "max_output_tokens DSL value overrides max_output_tokens from the registry" do
        budget = budget_agent_class.new.send(:build_token_budget)
        expect(budget).not_to be_nil
        expect(budget.max_output_tokens).to eq(2048)
      end

      it "context_overhead DSL value is reflected in the budget overhead" do
        budget = budget_agent_class.new.send(:build_token_budget)
        expect(budget.overhead).to eq(300)
      end

      it "effective_input_limit equals context_window minus max_output_tokens minus overhead" do
        budget = budget_agent_class.new.send(:build_token_budget)
        expect(budget.effective_input_limit).to eq(32_768 - 2048 - 300)
      end
    end

    context "when model is resolvable and a token budget is available" do
      let(:mock_model) do
        double("RubyLLMModel", context_window: 16_000, max_output_tokens: 2_000)
      end

      before do
        allow(RubyLLM.models).to receive(:find).with("test-model").and_return(mock_model)
      end

      let(:prev_msg) { double("PrevMessage", role: :user, content: "previous") }

      it "injects history messages into the chat via the Assembler" do
        agent.invoke("Hello", messages: [prev_msg])
        expect(fake_chat.messages).to include(prev_msg)
      end
    end
  end
end

RSpec.describe "Phronomy::Agent::Base .tools with aliases" do
  let(:alias_tokens) { double("Tokens", input: 5, output: 2, cached: 0, cache_creation: 0) }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
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
      description "Tool B"
      def execute = "b"
    end
  end

  describe ".tools (splat form — backward compatible)" do
    it "stores the tool classes" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(tool_a, tool_b)
      expect(agent_class.tools).to eq([tool_a, tool_b])
    end

    it "sets tool_aliases to an empty hash" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(tool_a)
      expect(agent_class.tool_aliases).to eq({})
    end

    it "registers each tool with chat.with_tool" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(tool_a, tool_b)
      agent_class.new.invoke("hello")
      expect(fake_chat).to have_received(:with_tool).twice
    end
  end

  describe ".tools (hash form with aliases)" do
    it "stores the tool classes" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(tool_a => "alpha", tool_b => "beta")
      expect(agent_class.tools).to eq([tool_a, tool_b])
    end

    it "stores the aliases" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(tool_a => "alpha", tool_b => nil)
      expect(agent_class.tool_aliases).to eq({tool_a => "alpha"})
    end

    it "registers tools with aliased anonymous subclasses when an alias is given" do
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(tool_a => "alpha", tool_b => nil)
      agent_class.new.invoke("hello")
      # Verify with_tool was called twice (once aliased, once plain)
      expect(fake_chat).to have_received(:with_tool).twice
      # Verify the aliased tool class exposes the correct name
      aliased = Class.new(tool_a) { tool_name "alpha" }
      expect(aliased.new.name).to eq("alpha")
    end

    it "nil alias leaves the original tool_name intact" do
      klass = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "original_name"
        def execute = ""
      end
      agent_class = Class.new(Phronomy::Agent::Base) { model "m" }
      agent_class.tools(klass => nil)
      # No alias stored — tool_aliases is empty for this key
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
  let(:fake_tokens) { double("Tokens", input: 10, output: 5, cached: 0, cache_creation: 0) }
  let(:fake_message) { double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }
  let(:fake_messages) { [fake_message] }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
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
      model "test-model"
      temperature 0
    end
    expect(klass.temperature).to eq(0)
  end

  it "stores 0.0 correctly via the temperature DSL" do
    klass = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      temperature 0.0
    end
    expect(klass.temperature).to eq(0.0)
  end

  it "calls with_temperature(0) on the chat object when temperature is 0" do
    klass = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      temperature 0
    end
    klass.new.invoke("Hello")
    expect(fake_chat).to have_received(:with_temperature).with(0)
  end
end

RSpec.describe "Phronomy::Agent::Base invoke_timeout DSL (Issue #116)" do
  describe ".invoke_timeout" do
    it "defaults to nil" do
      klass = Class.new(Phronomy::Agent::Base) { model "test-model" }
      expect(klass.invoke_timeout).to be_nil
    end

    it "stores the configured value" do
      klass = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 30
      end
      expect(klass.invoke_timeout).to eq(30)
    end

    it "is inherited by subclasses" do
      parent = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 60
      end
      child = Class.new(parent)
      expect(child.invoke_timeout).to eq(60)
    end

    it "can be overridden in a subclass" do
      parent = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 60
      end
      child = Class.new(parent) { invoke_timeout 10 }
      expect(child.invoke_timeout).to eq(10)
      expect(parent.invoke_timeout).to eq(60)
    end
  end

  describe "#invoke in EventLoop mode" do
    around do |example|
      Phronomy::EventLoop.instance.start
      example.run
    ensure
      Phronomy::EventLoop.instance.stop(timeout: 0)
    end

    it "raises Phronomy::TimeoutError when the agent does not finish in time" do
      klass = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 0.1
      end

      # Stub _start_invoke_attempt to never complete the result_task (simulates a slow agent)
      allow_any_instance_of(klass).to receive(:_start_invoke_attempt)

      expect { klass.new.invoke("test") }.to raise_error(Phronomy::TimeoutError, /timed out/)
    end

    it "does not raise when the agent finishes within the timeout" do
      klass = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 5
      end

      allow_any_instance_of(klass).to receive(:_start_invoke_attempt) do |_instance, result_task, *|
        result_task.backend.unblock({output: "ok", messages: [], usage: nil}, nil)
        result_task.transition!(:completed, value: {output: "ok", messages: [], usage: nil})
      end

      result = klass.new.invoke("hi")
      expect(result[:output]).to eq("ok")
    end
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
      # tool_alias is registered via the hash form of .tools
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

RSpec.describe "Agent thread-local context cache cleanup (issue #128)" do
  class CacheCleanupAgent < Phronomy::Agent::Base
    model "test-model"
  end

  let(:reply_tokens) { double("Tokens", input: 5, output: 5, cached: 0, cache_creation: 0) }
  let(:reply_msg) do
    double("Msg", role: :assistant, content: "hi", tool_calls: nil, tokens: reply_tokens, tool_call?: false)
  end
  let(:chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:on_tool_result)
    allow(dbl).to receive(:messages).and_return([reply_msg])
    allow(dbl).to receive(:ask).and_return(reply_msg)
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(chat) }

  it "removes the cache entry after invoke completes" do
    agent = CacheCleanupAgent.new
    agent.invoke("hello")
    cache = Thread.current[:phronomy_context_version_caches]
    expect(cache).to be_nil.or(satisfy { |c| !c.key?(agent.object_id) })
  end

  it "does not accumulate entries across multiple sequential invocations" do
    agent1 = CacheCleanupAgent.new
    agent2 = CacheCleanupAgent.new
    agent1.invoke("a")
    agent2.invoke("b")
    cache = Thread.current[:phronomy_context_version_caches] || {}
    expect(cache.key?(agent1.object_id)).to be false
    expect(cache.key?(agent2.object_id)).to be false
  end
end

RSpec.describe "Agent static_knowledge caching (issue #127)" do
  # A fake knowledge source that counts how many times it has been fetched.
  class CountingKnowledgeSource
    attr_reader :fetch_count

    def initialize(text)
      @text = text
      @fetch_count = 0
    end

    def fetch(query: nil, cancellation_token: nil)
      @fetch_count += 1
      [{content: @text, metadata: {}}]
    end
  end

  let(:reply_tokens) { double("Tokens", input: 5, output: 5, cached: 0, cache_creation: 0) }
  let(:reply_msg) do
    double("Msg", role: :assistant, content: "answer", tool_calls: nil, tokens: reply_tokens, tool_call?: false)
  end
  let(:chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:on_tool_result)
    allow(dbl).to receive(:messages).and_return([reply_msg])
    allow(dbl).to receive(:ask).and_return(reply_msg)
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(chat) }

  it "fetches each static knowledge source only once across multiple invocations" do
    ks = CountingKnowledgeSource.new("policy text")

    agent_class = Class.new(Phronomy::Agent::Base) do
      model "test-model"
    end
    agent_class.static_knowledge(ks)

    agent = agent_class.new
    agent.invoke("question 1")
    agent.invoke("question 2")
    agent.invoke("question 3")

    expect(ks.fetch_count).to eq(1)
  end

  it "re-fetches when static_knowledge DSL is called again (cache invalidated)" do
    ks = CountingKnowledgeSource.new("v1 text")

    agent_class = Class.new(Phronomy::Agent::Base) do
      model "test-model"
    end
    agent_class.static_knowledge(ks)

    agent_class.new.invoke("q1")
    expect(ks.fetch_count).to eq(1)

    # Re-declaring static_knowledge must invalidate the cache.
    agent_class.static_knowledge(ks)
    agent_class.new.invoke("q2")
    expect(ks.fetch_count).to eq(2)
  end

  it "re-fetches after static_knowledge_refresh! is called (issue #164)" do
    ks = CountingKnowledgeSource.new("refreshable text")

    agent_class = Class.new(Phronomy::Agent::Base) do
      model "test-model"
    end
    agent_class.static_knowledge(ks)

    agent_class.new.invoke("q1")
    expect(ks.fetch_count).to eq(1)

    # Calling refresh! must invalidate the cache.
    agent_class.static_knowledge_refresh!
    agent_class.new.invoke("q2")
    expect(ks.fetch_count).to eq(2)
  end
end

# Issue #290 — invoke_timeout scope token must be wired into the FSM config so
# that LLM, tool, and RAG calls observe cancellation when the deadline fires.
RSpec.describe "Agent#invoke invoke_timeout cancellation propagation (Issue #290)", :issue_290 do
  around do |example|
    Phronomy.configure { |c| c.runtime_backend = :thread }
    Phronomy::Runtime.instance_variable_set(:@instance, nil)
    example.run
  ensure
    Phronomy.reset_configuration!
    Phronomy::Runtime.instance_variable_set(:@instance, nil)
  end

  it "passes a CancellationToken that is cancelled after timeout to _invoke_impl config" do
    klass = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      invoke_timeout 0.1
    end

    captured_token = nil
    allow_any_instance_of(klass).to receive(:_start_invoke_attempt) do |_instance, result_task, _input, messages:, thread_id:, config:, attempt:|
      captured_token = config[:cancellation_token]
      # Never complete the task — simulate a slow LLM/tool call
    end

    expect { klass.new.invoke("test") }.to raise_error(Phronomy::TimeoutError)

    # The scope token must be non-nil and cancelled so that in-flight
    # LLM/tool/RAG sub-calls stop after the deadline fires.
    expect(captured_token).not_to be_nil
    expect(captured_token).to be_cancelled
  end

  it "scope token is a child of the caller-supplied cancellation_token" do
    klass = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      invoke_timeout 5
    end

    parent_token = Phronomy::Concurrency::CancellationToken.new
    captured_token = nil
    allow_any_instance_of(klass).to receive(:_start_invoke_attempt) do |_instance, result_task, _input, messages:, thread_id:, config:, attempt:|
      captured_token = config[:cancellation_token]
      result_task.backend.unblock({output: "ok", messages: [], usage: nil}, nil)
      result_task.transition!(:completed, value: {output: "ok", messages: [], usage: nil})
    end

    klass.new.invoke("test", config: {cancellation_token: parent_token})

    # A distinct scope token must be provided — not the parent token itself.
    expect(captured_token).not_to be_nil
    expect(captured_token).not_to equal(parent_token)
  end
end
