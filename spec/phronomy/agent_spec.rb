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

    describe "DSL inheritance via Class.new (anonymous subclass)" do
      let(:tool_a) {
        Class.new(Phronomy::Tool::Base) {
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
        tool_b = Class.new(Phronomy::Tool::Base) {
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
  let(:final_message) { double("Message", role: :assistant, content: "Final answer", tool_calls: nil, tokens: final_tokens) }
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
  let(:tool_message) { double("Message", role: :assistant, content: "Tool called", tool_calls: [{name: "search"}]) }
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
    let(:tool_call_msg) { double("ToolCallMessage", role: :assistant, content: nil, tool_calls: [double("ToolCall", name: "add")], tokens: tool_tokens) }
    let(:final_answer_msg) { double("FinalMessage", role: :assistant, content: "The answer is 7", tool_calls: nil, tokens: final_tokens2) }

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

  describe "messages integration" do
    class MessagesReactAgent < Phronomy::Agent::ReactAgent
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

    before do
      allow(RubyLLM).to receive(:chat).and_return(mem_chat)
    end

    subject(:agent) { MessagesReactAgent.new }

    it "injects provided messages into the chat before asking" do
      agent.invoke("Hello", messages: [prev_msg])
      expect(mem_chat.messages).to include(prev_msg)
    end

    it "works without messages in config" do
      agent.invoke("Hello", config: {})
      expect(mem_chat.messages).not_to include(prev_msg)
    end
  end

  describe "iterations_exhausted flag" do
    class ExhaustedReactAgent < Phronomy::Agent::ReactAgent
      model "test-model"
      max_iterations 1
    end

    # A chat double that always returns a tool call (never terminates)
    let(:always_tool_msg) do
      double("AlwaysToolMsg", role: :assistant, content: nil,
        tool_calls: [double("tc", name: "noop")],
        tokens: double("Tok", input: 1, output: 1, cached: 0, cache_creation: 0))
    end
    let(:stuck_chat) do
      dbl = double("StuckChat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:ask).and_return(always_tool_msg)
      allow(dbl).to receive(:messages).and_return([always_tool_msg])
      allow(dbl).to receive(:last_message).and_return(always_tool_msg)
      allow(dbl).to receive(:complete).and_return(always_tool_msg)
      allow(dbl).to receive(:add_message)
      dbl
    end

    it "returns iterations_exhausted: false on normal completion" do
      result = SimpleReactAgent.new.invoke("Hello")
      expect(result[:iterations_exhausted]).to be false
    end

    it "returns iterations_exhausted: true when max_iterations is reached" do
      allow(RubyLLM).to receive(:chat).and_return(stuck_chat)
      result = ExhaustedReactAgent.new.invoke("Hello")
      expect(result[:iterations_exhausted]).to be true
    end

    it "does not return a raw tool result as output when iterations exhausted" do
      # Simulate a cycle where the last assistant message is a tool-call and
      # the conversation history also contains a tool result (role: :tool).
      # When iterations are exhausted, the tool result string must NOT become
      # the agent's output.
      tool_result_msg = double("ToolResultMsg", role: :tool, content: "raw_tool_output",
        tool_calls: nil,
        tokens: double("Tok", input: 1, output: 1, cached: 0, cache_creation: 0))
      exhausted_chat = double("ExhaustedChat")
      allow(exhausted_chat).to receive(:with_instructions).and_return(exhausted_chat)
      allow(exhausted_chat).to receive(:with_tool).and_return(exhausted_chat)
      allow(exhausted_chat).to receive(:ask).and_return(always_tool_msg)
      # Messages: tool_result first, then another tool-call message last so that
      # done=false and iterations_exhausted=true, while tool result is in history.
      allow(exhausted_chat).to receive(:messages).and_return([tool_result_msg, always_tool_msg])
      allow(exhausted_chat).to receive(:last_message).and_return(always_tool_msg)
      allow(exhausted_chat).to receive(:complete).and_return(always_tool_msg)
      allow(exhausted_chat).to receive(:add_message)
      allow(RubyLLM).to receive(:chat).and_return(exhausted_chat)
      result = ExhaustedReactAgent.new.invoke("Hello")
      expect(result[:output]).not_to eq("raw_tool_output")
      expect(result[:iterations_exhausted]).to be true
    end
  end

  describe "#stream iterations_exhausted flag" do
    class ExhaustedStreamAgent < Phronomy::Agent::ReactAgent
      model "test-model"
      max_iterations 1
    end

    let(:normal_msg) do
      double("NormalMsg", role: :assistant, content: "done", tool_calls: nil,
        tokens: double("Tok", input: 1, output: 1, cached: 0, cache_creation: 0))
    end
    let(:normal_chat) do
      dbl = double("NormalStreamChat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:messages).and_return([normal_msg])
      allow(dbl).to receive(:last_message).and_return(normal_msg)
      allow(dbl).to receive(:add_message)
      allow(dbl).to receive(:on_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask).and_return(normal_msg)
      dbl
    end

    it "returns iterations_exhausted: false when LLM completes without tool calls" do
      allow(RubyLLM).to receive(:chat).and_return(normal_chat)
      result = SimpleReactAgent.new.stream("Hello") { |_e| }
      expect(result[:iterations_exhausted]).to be false
    end

    it "returns iterations_exhausted: true when max_iterations is reached in stream" do
      # Reuse stuck_chat from the outer context via a local double
      stuck = double("StuckStreamChat")
      always_msg = double("AlwaysToolMsg", role: :assistant, content: nil,
        tool_calls: [double("tc", name: "noop")],
        tokens: double("Tok", input: 1, output: 1, cached: 0, cache_creation: 0))
      allow(stuck).to receive(:with_instructions).and_return(stuck)
      allow(stuck).to receive(:with_tool).and_return(stuck)
      allow(stuck).to receive(:messages).and_return([always_msg])
      allow(stuck).to receive(:last_message).and_return(always_msg)
      allow(stuck).to receive(:add_message)
      allow(stuck).to receive(:on_tool_call)
      allow(stuck).to receive(:on_tool_result)
      allow(stuck).to receive(:ask).and_return(always_msg)
      allow(RubyLLM).to receive(:chat).and_return(stuck)
      result = ExhaustedStreamAgent.new.stream("Hello") { |_e| }
      expect(result[:iterations_exhausted]).to be true
    end
  end

  describe "caller identity propagation to tracer" do
    subject(:agent) { SimpleReactAgent.new }
    let(:spy_tracer) do
      Class.new(Phronomy::Tracing::NullTracer) do
        attr_reader :last_span_attributes

        def start_span(name, **attributes)
          @last_span_attributes = attributes
          super
        end
      end.new
    end

    let(:reply_msg) { double("Msg", role: :assistant, content: "ok", tool_calls: nil, tokens: double("Tok", input: 1, output: 1, cached: 0, cache_creation: 0)) }
    let(:spy_chat) do
      dbl = double("Chat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:with_temperature).and_return(dbl)
      allow(dbl).to receive(:messages).and_return([reply_msg])
      allow(dbl).to receive(:last_message).and_return(reply_msg)
      allow(dbl).to receive(:add_message)
      allow(dbl).to receive(:ask).and_return(reply_msg)
      dbl
    end

    before do
      Phronomy.configure { |c| c.tracer = spy_tracer }
      allow(RubyLLM).to receive(:chat).and_return(spy_chat)
    end

    after { Phronomy.configure { |c| c.tracer = Phronomy::Tracing::NullTracer.new } }

    it "forwards user_id to the tracer span attributes" do
      agent.invoke("Hello", config: {user_id: "u-42"})
      expect(spy_tracer.last_span_attributes[:user_id]).to eq("u-42")
    end

    it "forwards session_id to the tracer span attributes" do
      agent.invoke("Hello", config: {session_id: "sess-abc"})
      expect(spy_tracer.last_span_attributes[:session_id]).to eq("sess-abc")
    end

    it "does not include user_id key when not supplied" do
      agent.invoke("Hello", config: {})
      expect(spy_tracer.last_span_attributes).not_to have_key(:user_id)
    end

    it "does not include session_id key when not supplied" do
      agent.invoke("Hello", config: {})
      expect(spy_tracer.last_span_attributes).not_to have_key(:session_id)
    end
  end
end

# Regression tests for GitHub Issue #30 (ID-12):
# The temperature DSL uses `if val` to guard the assignment, which was reported
# to fail silently for temperature(0). In Ruby, 0 and 0.0 are truthy, so this
# code is actually correct. These specs document and lock in the correct behavior.
RSpec.describe "Phronomy::Agent::Base temperature DSL zero value (Issue #30 / ID-12)" do
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
      Phronomy.configure { |c| c.event_loop = true }
      Phronomy::EventLoop.instance.start
      example.run
    ensure
      Phronomy::EventLoop.instance.stop
      Phronomy.configure { |c| c.event_loop = false }
    end

    it "raises Phronomy::TimeoutError when the agent does not finish in time" do
      klass = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 0.1
      end

      # Stub _invoke_impl to block indefinitely
      allow_any_instance_of(klass).to receive(:_invoke_impl) do
        sleep 10
      end

      expect { klass.new.invoke("test") }.to raise_error(Phronomy::TimeoutError, /timed out/)
    end

    it "does not raise when the agent finishes within the timeout" do
      klass = Class.new(Phronomy::Agent::Base) do
        model "test-model"
        invoke_timeout 5
      end

      allow_any_instance_of(klass).to receive(:_invoke_impl)
        .and_return({output: "ok", messages: [], usage: nil})

      result = klass.new.invoke("hi")
      expect(result[:output]).to eq("ok")
    end
  end
end

RSpec.describe "Phronomy::Agent::Base tool_aliases inheritance (Issue #126)" do
  let(:tool_a) { Class.new(Phronomy::Tool::Base) { description "a" } }
  let(:tool_b) { Class.new(Phronomy::Tool::Base) { description "b" } }

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
    double("Msg", role: :assistant, content: "hi", tool_calls: nil, tokens: reply_tokens)
  end
  let(:chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
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
    double("Msg", role: :assistant, content: "answer", tool_calls: nil, tokens: reply_tokens)
  end
  let(:chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
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
