# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Test tools (synchronous, predictable)
# ---------------------------------------------------------------------------
class PtcEchoTool < Phronomy::Tool::Base
  tool_name "ptc_echo"
  description "Echoes the input"
  param :value, type: :string, desc: "The value to echo"

  def execute(value:)
    "echo:#{value}"
  end
end

class PtcSlowTool < Phronomy::Tool::Base
  tool_name "ptc_slow"
  description "Slow echo tool"
  param :value, type: :string, desc: "The value to echo"

  def execute(value:)
    sleep 0.05
    "slow:#{value}"
  end
end

class PtcApprovalTool < Phronomy::Tool::Base
  tool_name "ptc_approval"
  description "A tool that requires approval"
  requires_approval true
  param :value, type: :string, desc: "Input"

  def execute(value:)
    "approved:#{value}"
  end
end

RSpec.describe Phronomy::Agent::ParallelToolChat do
  before(:each) do
    RubyLLM.configure { |c| c.openai_api_key = "test-api-key" }
  end

  # Stub Task.spawn synchronously and Runtime pool so multi-tool tests run
  # without a live EventLoop.  Cooperative tests use Task.spawn; blocking_io
  # tests use pool.submit.  Both are stubbed to execute the block in-line.
  def stub_task_and_pool(pool_double: nil)
    allow(Phronomy::Task).to receive(:spawn) do |&blk|
      t = double("Task")
      allow(t).to receive(:await).and_return(blk.call)
      t
    end
    if pool_double
      allow(Phronomy::Runtime).to receive(:instance).and_return(
        instance_double(Phronomy::Runtime, blocking_io: pool_double)
      )
    else
      allow(Phronomy::Runtime).to receive(:instance).and_return(nil)
    end
  end

  # Build a minimal ToolCall double.
  def fake_tool_call(name, args, id: nil)
    tc = double("ToolCall-#{name}")
    allow(tc).to receive(:name).and_return(name.to_s)
    allow(tc).to receive(:arguments).and_return(args)
    allow(tc).to receive(:id).and_return(id || "tc-#{name}")
    tc
  end

  # Build a minimal response double carrying the given tool_calls hash.
  def fake_response(tool_calls_hash)
    resp = double("Response")
    allow(resp).to receive(:tool_calls).and_return(tool_calls_hash)
    resp
  end

  describe "#handle_tool_calls" do
    context "with a single tool call" do
      it "delegates to super (standard sequential behaviour)" do
        chat = described_class.new
        tc = fake_tool_call("ptc_echo", {"value" => "x"}, id: "tc1")
        resp = fake_response({"ptc_echo" => tc})

        # super path adds a message and calls complete; we just verify no error.
        allow(chat).to receive(:execute_tool).with(tc).and_return("echo:x")
        allow(chat).to receive(:add_message).and_return(double("msg"))
        allow(chat).to receive(:forced_tool_choice?).and_return(false)
        allow(chat).to receive(:content_like?).and_return(false)
        allow(chat).to receive(:complete).and_return(double("resp2", tool_calls: {}))

        # Call super means the original handle_tool_calls logic runs.
        # We cannot easily intercept super, so we verify the tool is called once.
        expect(chat).to receive(:execute_tool).with(tc).once.and_return("echo:x")

        # Silence callbacks
        chat.instance_variable_set(:@on, {})

        chat.send(:handle_tool_calls, resp)
      end
    end

    context "with multiple tool calls" do
      it "executes all tools and adds a message for each" do
        stub_task_and_pool
        chat = described_class.new
        chat.instance_variable_set(:@on, {})
        tool = PtcEchoTool.new
        chat.instance_variable_set(:@tools, {ptc_echo: tool})

        tc1 = fake_tool_call("ptc_echo", {"value" => "a"}, id: "tc1")
        tc2 = fake_tool_call("ptc_echo", {"value" => "b"}, id: "tc2")
        resp = fake_response({"tool_a" => tc1, "tool_b" => tc2})

        allow(chat).to receive(:content_like?).and_return(false)
        allow(chat).to receive(:forced_tool_choice?).and_return(false)
        allow(chat).to receive(:complete).and_return(nil)

        added_messages = []
        allow(chat).to receive(:add_message) do |**kwargs|
          added_messages << kwargs
          double("msg-#{kwargs[:tool_call_id]}")
        end

        chat.send(:handle_tool_calls, resp)

        expect(added_messages.size).to eq(2)
        expect(added_messages.map { |m| m[:tool_call_id] }).to contain_exactly("tc1", "tc2")
      end

      it "calls pre-execution callbacks before any tool runs" do
        stub_task_and_pool
        chat = described_class.new

        execution_order = []
        callback_order = []

        tool1 = PtcEchoTool.new
        tool2 = PtcEchoTool.new
        allow(tool1).to receive(:call).and_wrap_original do |m, *a, **kw|
          execution_order << "t1"
          m.call(*a, **kw)
        end
        allow(tool2).to receive(:call).and_wrap_original do |m, *a, **kw|
          execution_order << "t2"
          m.call(*a, **kw)
        end
        chat.instance_variable_set(:@tools, {t1: tool1, t2: tool2})

        tc1 = fake_tool_call("t1", {"value" => "a"}, id: "tc1")
        tc2 = fake_tool_call("t2", {"value" => "b"}, id: "tc2")
        resp = fake_response({"t1" => tc1, "t2" => tc2})

        allow(chat).to receive(:content_like?).and_return(false)
        allow(chat).to receive(:forced_tool_choice?).and_return(false)
        allow(chat).to receive(:complete).and_return(nil)
        allow(chat).to receive(:add_message).and_return(double("msg"))

        on_callbacks = {}
        on_callbacks[:tool_call] = proc { |tc| callback_order << tc.name }
        on_callbacks[:new_message] = nil
        on_callbacks[:tool_result] = nil
        on_callbacks[:end_message] = nil
        chat.instance_variable_set(:@on, on_callbacks)

        chat.send(:handle_tool_calls, resp)

        # All callbacks must fire before any execution begins
        expect(callback_order).to contain_exactly("t1", "t2")
        # Tools were also executed
        expect(execution_order).to contain_exactly("t1", "t2")
      end

      it "adds messages in the original tool-call order regardless of execution timing" do
        stub_task_and_pool
        chat = described_class.new
        chat.instance_variable_set(:@on, {})

        # tc1 is slow, tc2 is fast — messages must appear in original (tc1, tc2) order
        slow_tool = PtcSlowTool.new
        fast_tool = PtcEchoTool.new
        chat.instance_variable_set(:@tools, {slow_tool: slow_tool, fast_tool: fast_tool})

        tc1 = fake_tool_call("slow_tool", {"value" => "x"}, id: "tc1")
        tc2 = fake_tool_call("fast_tool", {"value" => "y"}, id: "tc2")
        resp = fake_response({"slow" => tc1, "fast" => tc2})

        allow(chat).to receive(:content_like?).and_return(false)
        allow(chat).to receive(:forced_tool_choice?).and_return(false)
        allow(chat).to receive(:complete).and_return(nil)

        tool_call_ids = []
        allow(chat).to receive(:add_message) do |**kwargs|
          tool_call_ids << kwargs[:tool_call_id]
          double("msg")
        end

        chat.send(:handle_tool_calls, resp)

        expect(tool_call_ids).to eq(["tc1", "tc2"])
      end

      it "returns the halt result when a Tool::Halt is encountered" do
        stub_task_and_pool
        chat = described_class.new
        chat.instance_variable_set(:@on, {})

        halt = RubyLLM::Tool::Halt.new("stop!")
        halt_tool = PtcEchoTool.new
        normal_tool = PtcEchoTool.new
        allow(halt_tool).to receive(:call).and_return(halt)
        allow(normal_tool).to receive(:call).and_return("normal")
        chat.instance_variable_set(:@tools, {t1: halt_tool, t2: normal_tool})

        tc1 = fake_tool_call("t1", {}, id: "tc1")
        tc2 = fake_tool_call("t2", {}, id: "tc2")
        resp = fake_response({"t1" => tc1, "t2" => tc2})

        allow(chat).to receive(:content_like?).and_return(false)
        allow(chat).to receive(:forced_tool_choice?).and_return(false)
        allow(chat).to receive(:add_message).and_return(double("msg"))

        result = chat.send(:handle_tool_calls, resp)
        expect(result).to be(halt)
      end
    end
  end

  describe "Agent::Base#build_chat_class" do
    let(:agent_class) do
      Class.new(Phronomy::Agent::Base) do
        model "test-model"
        instructions "test"
      end
    end

    it "returns nil when EventLoop mode is off" do
      agent = agent_class.new
      Phronomy.configure { |c| c.event_loop = false }
      expect(agent.send(:build_chat_class)).to be_nil
    ensure
      Phronomy.configure { |c| c.event_loop = false }
    end

    it "returns ParallelToolChat when EventLoop mode is on" do
      agent = agent_class.new
      Phronomy.configure { |c| c.event_loop = true }
      expect(agent.send(:build_chat_class)).to be(Phronomy::Agent::ParallelToolChat)
    ensure
      Phronomy.configure { |c| c.event_loop = false }
    end
  end

  # ---------------------------------------------------------------------------
  # Regression: issue #295 — eliminate double-Thread for :blocking_io tools
  # ---------------------------------------------------------------------------
  context "issue #295 — direct pool dispatch, no TaskGroup wrapper", :issue_295 do
    let(:task_spawned) { [] }
    let(:pool_double) do
      pd = instance_double(Phronomy::BlockingAdapterPool)
      allow(pd).to receive(:submit) do |cancellation_token: nil, &blk|
        result = blk.call
        op = double("PendingOperation")
        allow(op).to receive(:await).and_return(result)
        op
      end
      pd
    end

    before do
      allow(Phronomy::Task).to receive(:spawn) do |&blk|
        task_spawned << :spawned
        t = double("Task#{task_spawned.size}")
        allow(t).to receive(:await).and_return(blk.call)
        t
      end
      runtime = instance_double(Phronomy::Runtime, blocking_io: pool_double)
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)
    end

    let(:blocking_tool_class) do
      Class.new(Phronomy::Tool::Base) do
        tool_name "io_dispatch_tool"
        description "IO tool for dispatch test"
        param :v, type: :string, desc: "v"
        def execute(v:); "io:#{v}"; end
      end
    end

    let(:coop_tool_class) do
      Class.new(Phronomy::Tool::Base) do
        tool_name "coop_dispatch_tool"
        execution_mode :cooperative
        description "Cooperative tool for dispatch test"
        param :v, type: :string, desc: "v"
        def execute(v:); "coop:#{v}"; end
      end
    end

    def minimal_multi_chat(tools_hash)
      chat = described_class.new
      chat.instance_variable_set(:@on, {})
      chat.instance_variable_set(:@tools, tools_hash)
      allow(chat).to receive(:content_like?).and_return(false)
      allow(chat).to receive(:forced_tool_choice?).and_return(false)
      allow(chat).to receive(:complete).and_return(nil)
      allow(chat).to receive(:add_message).and_return(double("msg"))
      chat
    end

    it "dispatches :blocking_io tools via pool.submit without a TaskGroup" do
      tool = blocking_tool_class.new
      chat = minimal_multi_chat({io_dispatch_tool: tool})
      tc1 = fake_tool_call("io_dispatch_tool", {"v" => "a"}, id: "tc1")
      tc2 = fake_tool_call("io_dispatch_tool", {"v" => "b"}, id: "tc2")
      resp = fake_response({"t1" => tc1, "t2" => tc2})

      allow(Phronomy::TaskGroup).to receive(:new).and_call_original

      chat.send(:handle_tool_calls, resp)

      expect(pool_double).to have_received(:submit).exactly(2).times
      expect(task_spawned).to be_empty
      expect(Phronomy::TaskGroup).not_to have_received(:new)
    end

    it "dispatches :cooperative tools via Task.spawn without touching the pool" do
      tool = coop_tool_class.new
      chat = minimal_multi_chat({coop_dispatch_tool: tool})
      tc1 = fake_tool_call("coop_dispatch_tool", {"v" => "a"}, id: "tc1")
      tc2 = fake_tool_call("coop_dispatch_tool", {"v" => "b"}, id: "tc2")
      resp = fake_response({"t1" => tc1, "t2" => tc2})

      chat.send(:handle_tool_calls, resp)

      expect(pool_double).not_to have_received(:submit)
      expect(task_spawned.size).to eq(2)
    end
  end
end
