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
  let(:fake_message) { double("Message", content: "LLM response", tool_calls: nil, tokens: fake_tokens) }
  let(:fake_messages) { [fake_message] }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
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

    context "with memory and thread_id in config" do
      let(:prev_msg) { double("PrevMessage", role: :user, content: "previous") }
      let(:memory) do
        mem = instance_double(Phronomy::Memory::WindowMemory)
        allow(mem).to receive(:load_messages).and_return([prev_msg])
        allow(mem).to receive(:save_messages)
        mem
      end

      it "loads previous messages from memory before asking" do
        agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
        expect(memory).to have_received(:load_messages).with(thread_id: "t1", token_budget: nil)
      end

      it "injects the loaded message into the chat" do
        agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
        expect(fake_chat.messages).to include(prev_msg)
      end

      it "saves updated messages back to memory after invoke" do
        agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
        expect(memory).to have_received(:save_messages).with(
          thread_id: "t1",
          messages: fake_chat.messages
        )
      end

      it "skips memory when config has no thread_id" do
        agent.invoke("Hello", config: {memory: memory})
        expect(memory).not_to have_received(:load_messages)
        expect(memory).not_to have_received(:save_messages)
      end

      it "skips memory when config has no memory" do
        agent.invoke("Hello", config: {thread_id: "t1"})
        # no error is raised — memory is simply not used
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
          context_overhead  300
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

    context "when model is resolvable and a real token_budget is built" do
      let(:mock_model) do
        double("RubyLLMModel", context_window: 16_000, max_output_tokens: 2_000)
      end

      before do
        allow(RubyLLM.models).to receive(:find).with("test-model").and_return(mock_model)
      end

      let(:prev_msg) { double("PrevMessage", role: :user, content: "previous") }
      let(:memory) do
        mem = instance_double(Phronomy::Memory::WindowMemory)
        allow(mem).to receive(:load_messages).and_return([prev_msg])
        allow(mem).to receive(:save_messages)
        mem
      end

      it "passes a non-nil TokenBudget to load_messages" do
        agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
        expect(memory).to have_received(:load_messages) do |**kwargs|
          expect(kwargs[:token_budget]).to be_a(Phronomy::Context::TokenBudget)
          expect(kwargs[:token_budget].effective_input_limit).to eq(16_000 - 2_000)
        end
      end

      it "injects budget-filtered history messages into the chat" do
        agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
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
    allow(dbl).to receive(:ask).and_return(double("Msg", content: "ok", tool_calls: nil, tokens: alias_tokens))
    allow(dbl).to receive(:messages).and_return([])
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

  let(:tool_a) do
    Class.new(Phronomy::Tool::Base) do
      description "Tool A"
      def execute = "a"
    end
  end

  let(:tool_b) do
    Class.new(Phronomy::Tool::Base) do
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
      klass = Class.new(Phronomy::Tool::Base) do
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

RSpec.describe Phronomy::Agent::ReactAgent do
  # Chat mock that completes immediately without tool calls
  let(:final_tokens) { double("Tokens", input: 20, output: 10, cached: 0, cache_creation: 0) }
  let(:final_message) { double("Message", content: "Final answer", tool_calls: nil, tokens: final_tokens) }
  let(:messages_list) { [final_message] }
  let(:done_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:ask).and_return(final_message)
    allow(dbl).to receive(:messages).and_return(messages_list)
    allow(dbl).to receive(:last_message).and_return(final_message)
    dbl
  end

  # Chat mock with two steps: tool call followed by final answer
  let(:tool_message) { double("Message", content: "Tool called", tool_calls: [{name: "search"}]) }
  let(:messages_with_tool) { [tool_message] }
  let(:tool_then_done_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:ask).and_return(tool_message)
    allow(dbl).to receive(:continue).and_return(final_message)
    allow(dbl).to receive(:messages).and_return(messages_with_tool, messages_list)
    allow(dbl).to receive(:last_message).and_return(tool_message, final_message)
    dbl
  end

  before do
    allow(RubyLLM).to receive(:chat).and_return(done_chat)
  end

  describe "#invoke" do
    class SimpleReactAgent < Phronomy::Agent::ReactAgent
      model "test-model"
    end

    subject(:agent) { SimpleReactAgent.new }

    it "completes in one step when there are no tool calls" do
      result = agent.invoke("Hello")
      expect(result[:output]).to eq("Final answer")
    end

    it "returns a Hash with :output and :messages" do
      result = agent.invoke("Hello")
      expect(result).to include(:output, :messages, :usage)
    end

    it "returns a TokenUsage as :usage" do
      result = agent.invoke("Hello")
      expect(result[:usage]).to be_a(Phronomy::TokenUsage)
      expect(result[:usage].input).to eq(20)
    end

    it "inherits from Base" do
      expect(SimpleReactAgent.ancestors).to include(Phronomy::Agent::Base)
    end

    it "works as a Runnable" do
      expect(agent).to respond_to(:batch)
    end
  end

  describe "tool call loop (function calling)" do
    class ToolReactAgent < Phronomy::Agent::ReactAgent
      model "test-model"
    end

    let(:tool_tokens) { double("Tokens", input: 15, output: 3, cached: 0, cache_creation: 0) }
    let(:final_tokens2) { double("Tokens", input: 12, output: 8, cached: 0, cache_creation: 0) }
    let(:tool_call_msg) { double("ToolCallMessage", content: nil, tool_calls: [double("ToolCall", name: "add")], tokens: tool_tokens) }
    let(:final_answer_msg) { double("FinalMessage", content: "The answer is 7", tool_calls: nil, tokens: final_tokens2) }

    let(:step1_chat) do
      dbl = double("Step1Chat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:ask).and_return(tool_call_msg)
      allow(dbl).to receive(:messages).and_return([tool_call_msg])
      dbl
    end

    let(:step2_chat) do
      dbl = double("Step2Chat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:add_message)
      allow(dbl).to receive(:complete).and_return(final_answer_msg)
      # Always return the finished state so done=true and the loop breaks.
      allow(dbl).to receive(:messages).and_return([tool_call_msg, final_answer_msg])
      dbl
    end

    before do
      allow(RubyLLM).to receive(:chat).and_return(step1_chat, step2_chat)
    end

    subject(:agent) { ToolReactAgent.new }

    it "calls ask on the first step with the user input" do
      agent.invoke("What is 3 plus 4?")
      expect(step1_chat).to have_received(:ask).with("What is 3 plus 4?")
    end

    it "calls complete on the second step when tool_calls are present" do
      agent.invoke("What is 3 plus 4?")
      expect(step2_chat).to have_received(:complete)
    end

    it "returns the final answer after tool execution" do
      result = agent.invoke("What is 3 plus 4?")
      expect(result[:output]).to eq("The answer is 7")
    end

    it "replays the tool call message into the next step chat" do
      agent.invoke("What is 3 plus 4?")
      expect(step2_chat).to have_received(:add_message).with(tool_call_msg)
    end
  end

  describe "memory integration" do
    class MemoryReactAgent < Phronomy::Agent::ReactAgent
      model "test-model"
    end

    let(:prev_msg) { double("PrevMessage", role: :user, content: "prev", tool_calls: nil) }
    let(:reply_tokens) { double("Tokens", input: 8, output: 4, cached: 0, cache_creation: 0) }
    let(:reply_msg) { double("ReplyMessage", role: :assistant, content: "reply", tool_calls: nil, tokens: reply_tokens) }

    # A self-contained chat double that already supports all ReactAgent step interactions.
    let(:mem_chat) do
      msgs = []
      dbl = double("MemChat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:messages) { msgs }
      allow(dbl).to receive(:ask) do
        msgs << reply_msg
        reply_msg
      end
      allow(dbl).to receive(:add_message) { |m| msgs << m }
      allow(dbl).to receive(:complete) do
        msgs << reply_msg
        reply_msg
      end
      dbl
    end

    let(:memory) do
      mem = instance_double(Phronomy::Memory::WindowMemory)
      allow(mem).to receive(:load_messages).and_return([prev_msg])
      allow(mem).to receive(:save_messages)
      mem
    end

    before do
      allow(RubyLLM).to receive(:chat).and_return(mem_chat)
    end

    subject(:agent) { MemoryReactAgent.new }

    it "loads previous messages from memory before invoking" do
      agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
      expect(memory).to have_received(:load_messages).with(thread_id: "t1")
    end

    it "injects the loaded message into the chat before asking" do
      agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
      # prev_msg was seeded → step called continue (messages.any?) → reply_msg added
      expect(mem_chat.messages).to include(prev_msg)
    end

    it "saves final messages back to memory after completing" do
      result = agent.invoke("Hello", config: {thread_id: "t1", memory: memory})
      expect(memory).to have_received(:save_messages).with(
        thread_id: "t1",
        messages: result[:messages]
      )
    end

    it "skips memory when no thread_id is provided" do
      agent.invoke("Hello", config: {memory: memory})
      expect(memory).not_to have_received(:load_messages)
      expect(memory).not_to have_received(:save_messages)
    end
  end
end
