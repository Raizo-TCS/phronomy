# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Shared test fixtures
# ---------------------------------------------------------------------------
class SuspendTestTool < Phronomy::Tool::Base
  tool_name "suspend_test"
  description "A tool requiring approval for suspend/resume tests"
  requires_approval true
  param :value, type: :string, desc: "Input"

  def execute(value:)
    "executed: #{value}"
  end
end

class SuspendTestAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a test assistant."
  tools SuspendTestTool
end

class NoApprovalToolAgent < Phronomy::Agent::Base
  model "test-model"
  tools(Class.new(Phronomy::Tool::Base) do
    tool_name "plain_tool"
    description "Plain tool with no approval requirement"
    param :v, type: :string, desc: "v"
    def execute(v:) = "ok"
  end)
end

# ---------------------------------------------------------------------------
RSpec.describe Phronomy::Agent::SuspendSignal do
  let(:signal) { described_class.new(tool_name: "my_tool", args: {"x" => 1}, tool_call_id: "call_abc") }

  it "is a StandardError subclass" do
    expect(described_class.ancestors).to include(StandardError)
  end

  it "exposes #tool_name" do
    expect(signal.tool_name).to eq("my_tool")
  end

  it "exposes #args" do
    expect(signal.args).to eq("x" => 1)
  end

  it "exposes #tool_call_id" do
    expect(signal.tool_call_id).to eq("call_abc")
  end

  it "has a descriptive message" do
    expect(signal.message).to match(/my_tool/)
  end
end

# ---------------------------------------------------------------------------
RSpec.describe Phronomy::Agent::Checkpoint do
  let(:msg) { double("Msg", role: :user, content: "hi") }
  let(:checkpoint) do
    described_class.new(
      thread_id: "t1",
      messages: [msg],
      pending_tool_name: "my_tool",
      pending_tool_args: {"x" => 1},
      pending_tool_call_id: "call_abc"
    )
  end

  it "exposes #thread_id" do
    expect(checkpoint.thread_id).to eq("t1")
  end

  it "exposes #messages as a frozen copy" do
    expect(checkpoint.messages).to eq([msg])
    expect(checkpoint.messages).to be_frozen
  end

  it "does not share the original messages array" do
    original = [msg]
    cp = described_class.new(
      thread_id: nil, messages: original,
      pending_tool_name: "t", pending_tool_args: {}, pending_tool_call_id: "c"
    )
    original << double("extra")
    expect(cp.messages.length).to eq(1)
  end

  it "exposes #pending_tool_name" do
    expect(checkpoint.pending_tool_name).to eq("my_tool")
  end

  it "exposes #pending_tool_args" do
    expect(checkpoint.pending_tool_args).to eq("x" => 1)
  end

  it "exposes #pending_tool_call_id" do
    expect(checkpoint.pending_tool_call_id).to eq("call_abc")
  end
end

# ---------------------------------------------------------------------------
RSpec.describe "Agent::Base suspend/resume" do
  let(:fake_tokens) { double("Tokens", input: 5, output: 3, cached: 0, cache_creation: 0) }
  let(:tool_instance) { SuspendTestTool.new }

  # A chat double whose #ask triggers the stored on_tool_call hook.
  def build_suspending_chat(messages_list: [], tools_hash: {})
    stored_hook = nil
    fake_tool_call = double("ToolCall",
      name: "suspend_test",
      arguments: {"value" => "hello"},
      id: "call_001")

    dbl = double("SuspendingChat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:messages) { messages_list }
    allow(dbl).to receive(:tools) { tools_hash }
    allow(dbl).to receive(:on_tool_call) { |&block| stored_hook = block }
    allow(dbl).to receive(:ask) do
      # Simulate RubyLLM calling the on_tool_call hook before executing the tool.
      stored_hook&.call(fake_tool_call)
      # If SuspendSignal is raised by the hook, ask never returns.
      nil
    end
    dbl
  end

  # A chat double used in #resume tests.
  def build_resume_chat(messages_list: [], tools_hash: {}, response_content: "Final answer")
    final_response = double("Response",
      content: response_content,
      tokens: fake_tokens)

    dbl = double("ResumeChat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:messages) { messages_list }
    allow(dbl).to receive(:tools) { tools_hash }
    allow(dbl).to receive(:add_message)
    allow(dbl).to receive(:complete).and_return(final_response)
    dbl
  end

  # -------------------------------------------------------------------------
  describe "#_register_suspension_hook!" do
    it "does not register a hook when @approval_handler is set" do
      agent = SuspendTestAgent.new
      agent.on_approval_required { |_n, _a| true }

      chat = double("Chat")
      expect(chat).not_to receive(:on_tool_call)

      agent.send(:_register_suspension_hook!, chat)
    end

    it "does not register a hook when no tool requires approval" do
      agent = NoApprovalToolAgent.new
      chat = double("Chat")
      expect(chat).not_to receive(:on_tool_call)
      agent.send(:_register_suspension_hook!, chat)
    end

    it "registers a hook when a tool requires approval and no handler is set" do
      agent = SuspendTestAgent.new
      registered = false
      chat = double("Chat")
      allow(chat).to receive(:on_tool_call) { registered = true }
      agent.send(:_register_suspension_hook!, chat)
      expect(registered).to be true
    end

    it "raises SuspendSignal via the hook when the approval tool is called" do
      agent = SuspendTestAgent.new
      stored_hook = nil
      chat = double("Chat")
      allow(chat).to receive(:on_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:tools).and_return(
        {suspend_test: tool_instance}
      )

      agent.send(:_register_suspension_hook!, chat)

      fake_tc = double("ToolCall", name: "suspend_test", arguments: {"value" => "x"}, id: "tc_42")
      expect { stored_hook.call(fake_tc) }.to raise_error(Phronomy::Agent::SuspendSignal) do |e|
        expect(e.tool_name).to eq("suspend_test")
        expect(e.args).to eq("value" => "x")
        expect(e.tool_call_id).to eq("tc_42")
      end
    end

    it "does NOT raise SuspendSignal for a non-approval tool" do
      agent = SuspendTestAgent.new
      stored_hook = nil
      plain_tool = double("PlainTool", requires_approval: false)
      chat = double("Chat")
      allow(chat).to receive(:on_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:tools).and_return(
        {suspend_test: tool_instance, other_tool: plain_tool}
      )

      agent.send(:_register_suspension_hook!, chat)

      non_approval_tc = double("ToolCall", name: "other_tool", arguments: {}, id: "tc_99")
      expect { stored_hook.call(non_approval_tc) }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  describe "#invoke with suspension" do
    before do
      allow(RubyLLM).to receive(:chat).and_return(
        build_suspending_chat(tools_hash: {suspend_test: tool_instance})
      )
    end

    subject(:agent) { SuspendTestAgent.new }

    it "returns :suspended => true" do
      result = agent.invoke("Please use the tool")
      expect(result[:suspended]).to be true
    end

    it "returns :output => nil" do
      result = agent.invoke("Please use the tool")
      expect(result[:output]).to be_nil
    end

    it "returns a Checkpoint in :checkpoint" do
      result = agent.invoke("Please use the tool")
      expect(result[:checkpoint]).to be_a(Phronomy::Agent::Checkpoint)
    end

    it "Checkpoint carries pending_tool_name" do
      result = agent.invoke("Please use the tool")
      expect(result[:checkpoint].pending_tool_name).to eq("suspend_test")
    end

    it "Checkpoint carries pending_tool_args" do
      result = agent.invoke("Please use the tool")
      expect(result[:checkpoint].pending_tool_args).to eq("value" => "hello")
    end

    it "Checkpoint carries pending_tool_call_id" do
      result = agent.invoke("Please use the tool")
      expect(result[:checkpoint].pending_tool_call_id).to eq("call_001")
    end

    it "does NOT suspend when @approval_handler is already registered" do
      agent.on_approval_required { |_n, _a| true }
      # When a handler is registered, _register_suspension_hook! returns early
      # and never calls chat.on_tool_call.  Verify by checking the hook coverage:
      # the test for this behaviour lives in #_register_suspension_hook! above.
      # Here we just assert that no SuspendSignal propagates to the caller.
      final_resp = double("Resp", content: "ok", tokens: fake_tokens)
      chat_dbl = build_resume_chat(
        tools_hash: {suspend_test: tool_instance},
        response_content: "ok"
      )
      allow(chat_dbl).to receive(:ask).and_return(final_resp)
      allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
      expect { agent.invoke("hi") }.not_to raise_error
    end
  end

  # -------------------------------------------------------------------------
  describe "#resume" do
    let(:msg_user) { double("UserMsg", role: :user, content: "hi") }
    let(:msg_assistant) { double("AssistantMsg", role: :assistant, content: nil) }
    let(:checkpoint) do
      Phronomy::Agent::Checkpoint.new(
        thread_id: "t1",
        messages: [msg_user, msg_assistant],
        pending_tool_name: "suspend_test",
        pending_tool_args: {"value" => "test_val"},
        pending_tool_call_id: "call_001"
      )
    end

    subject(:agent) { SuspendTestAgent.new }

    context "when approved: true" do
      before do
        allow(RubyLLM).to receive(:chat).and_return(
          build_resume_chat(
            tools_hash: {suspend_test: tool_instance},
            response_content: "The tool ran successfully."
          )
        )
      end

      it "returns :suspended => false" do
        result = agent.resume(checkpoint, approved: true)
        expect(result[:suspended]).to be false
      end

      it "returns the LLM final output" do
        result = agent.resume(checkpoint, approved: true)
        expect(result[:output]).to eq("The tool ran successfully.")
      end

      it "returns :messages" do
        result = agent.resume(checkpoint, approved: true)
        expect(result).to have_key(:messages)
      end

      it "calls tool instance when approved" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "done"
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        expect(tool_instance).to receive(:call).with({"value" => "test_val"}).and_return("executed: test_val")
        agent.resume(checkpoint, approved: true)
      end

      it "injects the tool result via add_message" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "done"
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        allow(tool_instance).to receive(:call).and_return("executed: test_val")
        agent.resume(checkpoint, approved: true)
        expect(chat_dbl).to have_received(:add_message).with(
          hash_including(
            role: :tool,
            content: "executed: test_val",
            tool_call_id: "call_001"
          )
        )
      end

      it "calls chat.complete to continue the LLM loop" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "done"
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        allow(tool_instance).to receive(:call).and_return("result")
        agent.resume(checkpoint, approved: true)
        expect(chat_dbl).to have_received(:complete)
      end

      it "loads checkpoint messages into the chat" do
        messages_list = []
        chat_dbl = build_resume_chat(
          messages_list: messages_list,
          tools_hash: {suspend_test: tool_instance},
          response_content: "done"
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        allow(tool_instance).to receive(:call).and_return("r")
        agent.resume(checkpoint, approved: true)
        expect(messages_list).to include(msg_user, msg_assistant)
      end
    end

    context "when approved: false" do
      before do
        allow(RubyLLM).to receive(:chat).and_return(
          build_resume_chat(
            tools_hash: {suspend_test: tool_instance},
            response_content: "Understood, I will not run the tool."
          )
        )
      end

      it "returns :suspended => false" do
        result = agent.resume(checkpoint, approved: false)
        expect(result[:suspended]).to be false
      end

      it "injects a denial message via add_message" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "Understood."
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        agent.resume(checkpoint, approved: false)
        expect(chat_dbl).to have_received(:add_message).with(
          hash_including(
            role: :tool,
            content: "Tool execution denied.",
            tool_call_id: "call_001"
          )
        )
      end

      it "does NOT call the tool's call method when denied" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "Understood."
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        expect(tool_instance).not_to receive(:call)
        agent.resume(checkpoint, approved: false)
      end
    end

    context "memory persistence in resume" do
      let(:memory) do
        m = instance_double(Phronomy::Memory::ConversationManager)
        allow(m).to receive(:save)
        m
      end

      it "saves to memory when thread_id and memory are in config" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "done"
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        allow(tool_instance).to receive(:call).and_return("r")
        agent.resume(checkpoint, approved: true, config: {thread_id: "t1", memory: memory})
        expect(memory).to have_received(:save).with(thread_id: "t1", messages: anything)
      end

      it "skips memory save when no thread_id is present" do
        chat_dbl = build_resume_chat(
          tools_hash: {suspend_test: tool_instance},
          response_content: "done"
        )
        allow(RubyLLM).to receive(:chat).and_return(chat_dbl)
        allow(tool_instance).to receive(:call).and_return("r")
        no_thread_checkpoint = Phronomy::Agent::Checkpoint.new(
          thread_id: nil,
          messages: [msg_user],
          pending_tool_name: "suspend_test",
          pending_tool_args: {"value" => "v"},
          pending_tool_call_id: "c1"
        )
        agent.resume(no_thread_checkpoint, approved: true, config: {memory: memory})
        expect(memory).not_to have_received(:save)
      end
    end
  end
end
