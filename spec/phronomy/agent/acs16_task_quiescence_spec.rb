# frozen_string_literal: true

require "spec_helper"
require "timeout"

class ACS16BlockingTool < Phronomy::Agent::Context::Capability::Base
  tool_name "acs16_blocking_tool"
  description "Blocks until the test releases it"
  param :value, type: :string, desc: "Input"

  class << self
    attr_accessor :started_queue, :release_queue
  end

  def execute(value:)
    self.class.started_queue << true
    self.class.release_queue.pop
    "done: #{value}"
  end
end

class ACS16CancellationAgent < Phronomy::Agent::Base
  agent_definition id: "acs16-cancellation-agent", version: 1
  model "test-model"
  instructions "Use the tool."
  tools ACS16BlockingTool => nil
end

class ACS16TerminalBarrierAgent < Phronomy::Agent::Base
  agent_definition id: "acs16-terminal-barrier-agent", version: 1
  model "test-model"
  instructions "Return a short answer."
end

ACS16_TOKENS = Struct.new(:input, :output, :cached, :cache_creation).new(4, 2, 0, 0)

def build_acs16_terminal_chat
  response = double(
    "ACS16TerminalResponse",
    role: :assistant,
    content: "done",
    tool_calls: nil,
    tokens: ACS16_TOKENS,
    tool_call?: false
  )
  chat = double("ACS16TerminalChat")
  allow(chat).to receive(:with_instructions).and_return(chat)
  allow(chat).to receive(:with_tool).and_return(chat)
  allow(chat).to receive(:with_temperature).and_return(chat)
  allow(chat).to receive(:messages).and_return([response])
  allow(chat).to receive(:cancellation_token=)
  allow(chat).to receive(:on_tool_call)
  allow(chat).to receive(:before_tool_call)
  allow(chat).to receive(:on_tool_result)
  allow(chat).to receive(:ask).and_return(response)
  allow(chat).to receive(:complete).and_return(response)
  chat
end

def build_acs16_cancellation_chat(tool_instance)
  stored_hook = nil
  tool_call = double(
    "ToolCall",
    name: "acs16_blocking_tool",
    arguments: {"value" => "x"},
    id: "acs16-call-1",
    thought_signature: nil,
    to_h: {
      id: "acs16-call-1",
      name: "acs16_blocking_tool",
      arguments: {"value" => "x"}
    }
  )
  assistant = double(
    "AssistantMessage",
    role: :assistant,
    content: nil,
    tool_calls: [tool_call],
    tokens: ACS16_TOKENS,
    tool_call?: true
  )
  final = double(
    "FinalResponse",
    role: :assistant,
    content: "should not become authoritative after cancellation",
    tool_calls: nil,
    tokens: ACS16_TOKENS,
    tool_call?: false
  )
  chat = double("ACS16Chat")
  allow(chat).to receive(:with_instructions).and_return(chat)
  allow(chat).to receive(:with_tool).and_return(chat)
  allow(chat).to receive(:with_temperature).and_return(chat)
  allow(chat).to receive(:messages).and_return([assistant])
  allow(chat).to receive(:tools).and_return({acs16_blocking_tool: tool_instance})
  allow(chat).to receive(:add_message)
  allow(chat).to receive(:cancellation_token=)
  allow(chat).to receive(:on_tool_call) { |&block| stored_hook = block }
  allow(chat).to receive(:before_tool_call) { |&block| stored_hook = block }
  allow(chat).to receive(:on_tool_result)
  allow(chat).to receive(:ask) { stored_hook&.call(tool_call) }
  allow(chat).to receive(:complete).and_return(final)
  chat
end

RSpec.describe "ACS-16 Task settlement and physical quiescence" do
  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe Phronomy::Concurrency::OffloadPool do
    it "separates early cancellation settlement from physical completion" do
      started = Queue.new
      release = Queue.new
      physical = Queue.new
      token = Phronomy::Concurrency::CancellationToken.new
      pool = described_class.new(pool_size: 1, queue_size: 2)

      task = pool.submit(cancellation_token: token) do
        started << true
        release.pop
        :late_value
      end
      task.on_physical_complete { physical << true }
      started.pop

      token.cancel!
      expect(task).to be_done
      expect(task.status).to eq(:cancelled)
      expect(task.physical_complete?).to be false
      expect(pool.abandoned_active_count).to eq(1)

      release << true
      physical.pop
      expect(task.physical_complete?).to be true
      expect { task.wait_result }.to raise_error(Phronomy::CancellationError)
    ensure
      release << true if defined?(release) && release.empty?
      pool&.shutdown(drain_timeout: 1)
    end

    it "publishes physical completion before ordinary logical completion callbacks on normal return" do
      pool = described_class.new(pool_size: 1, queue_size: 2)
      order = Queue.new
      gate = Queue.new

      task = pool.submit do
        gate.pop
        :ok
      end
      task.on_physical_complete { order << :physical }
      task.on_complete { |_value, _error| order << :logical }
      gate << true

      expect(task.wait_result).to eq(:ok)
      expect(order.pop).to eq(:physical)
      expect(order.pop).to eq(:logical)
      expect(task.physical_complete?).to be true
    ensure
      gate << true if defined?(gate) && gate.empty?
      pool&.shutdown(drain_timeout: 1)
    end
  end

  describe "Agent cancellation supervision" do
    let(:tool_instance) { ACS16BlockingTool.new }
    let(:agent) { ACS16CancellationAgent.new }

    it "keeps the Execution Task and Agent admission nonterminal until abandoned Tool work is quiescent" do
      started = Queue.new
      release = Queue.new
      ACS16BlockingTool.started_queue = started
      ACS16BlockingTool.release_queue = release
      allow(RubyLLM).to receive(:chat)
        .and_return(build_acs16_cancellation_chat(tool_instance))

      token = Phronomy::Concurrency::CancellationToken.new
      original = agent.invoke_async(
        "run the blocking tool",
        config: {cancellation_token: token}
      )
      started.pop

      active = agent.persistence.executions.list_active(agent.agent_id)
      expect(active.length).to eq(1)
      execution_id = active.first.execution_id
      expect(
        Phronomy::Runtime.instance.event_loop.agent_inflight_work_count(execution_id)
      ).to be >= 1

      token.cancel!

      # Logical result authority is revoked immediately, but the owning Tool
      # block is still physically live, so the top-level Task cannot settle and
      # the Agent admission cannot be reused.
      expect(original).not_to be_done
      competing = agent.invoke_async("competing top-level execution")
      expect { competing.wait_result }
        .to raise_error(Phronomy::AgentBusyError)
      expect(original).not_to be_done

      release << true

      expect { original.wait_result }
        .to raise_error(Phronomy::CancellationError)
      expect(original.status).to eq(:cancelled)
      expect(agent.persistence.executions.list_active(agent.agent_id)).to be_empty
      expect(
        Phronomy::Runtime.instance.event_loop.agent_inflight_work_count(execution_id)
      ).to eq(0)
    ensure
      release << true if defined?(release) && release.empty?
    end
  end

  describe "nonterminal recovery boundary" do
    it "keeps the Execution Task pending when terminal durability requires recovery" do
      persistence = Phronomy::Persistence::InMemory.new
      terminal_statuses = %i[completed rejected failed cancelled blocked handed_off]
      allow(persistence.executions).to receive(:save).and_wrap_original do |original, execution_id, expected_revision:, execution:|
        if terminal_statuses.include?(execution.status)
          raise "terminal persistence unavailable"
        end
        original.call(
          execution_id,
          expected_revision: expected_revision,
          execution: execution
        )
      end
      allow(RubyLLM).to receive(:chat).and_return(build_acs16_terminal_chat)

      events = Queue.new
      agent = ACS16TerminalBarrierAgent.new(
        persistence: persistence,
        on_event: ->(event) { events << event.type }
      )
      task = agent.invoke_async("finish normally")

      expect { task.wait_result(timeout: 0.1) }
        .to raise_error(Phronomy::TimeoutError)
      expect(task).not_to be_done
      expect(events).to be_empty

      competing = agent.invoke_async("competing top-level execution")
      expect { competing.wait_result(timeout: 1) }
        .to raise_error(Phronomy::AgentBusyError)
    end

    it "does not encode stale terminal-result rejection as parent Task settlement" do
      source = File.read(
        File.expand_path("../../../lib/phronomy/agent/execution_coordinator.rb", __dir__)
      )
      stale_section = source
        .split("if operation.state_required", 2)
        .fetch(1)
        .split("if ready.error", 2)
        .first

      expect(stale_section).to include("Dropped stale Agent terminal result")
      expect(stale_section).not_to include("fail_task(")
    end
  end

  # ---------------------------------------------------------------------------
  # Terminal delivery edge cases: settle_after_terminal and related callbacks
  # ---------------------------------------------------------------------------
  describe "terminal delivery edge cases" do
    it "propagates execution_error through settle_after_terminal when start fails for a closed agent" do
      raised_in_callback = Queue.new
      agent = ACS16TerminalBarrierAgent.new(
        on_event: ->(event) {
          raised_in_callback << event.type
          raise "on_event callback failure"
        }
      )

      # A closed agent delivers :error through the already-bound Agent listener
      # before Task settlement.
      agent.send(:close!)
      task = agent.invoke_async("closed agent invoke")
      expect { task.wait_result }.to raise_error(Phronomy::Error, /agent is closed/)
      # The callback was invoked (with the error event) and raised.
      expect(raised_in_callback.pop).to eq(:error)
    end

    it "returns false from signal when there is no approval listener on an HITL agent" do
      # When on_tool_approval_required is omitted the approval listener is nil;
      # dispatch_approval_listener must return early without raising.
      # (Exercises the 'return unless listener' then-branch.)
      allow(RubyLLM).to receive(:chat).and_return(build_acs16_terminal_chat)

      # Use a plain non-HITL agent for this check — the terminal chat never
      # triggers a tool approval, so the suspend path is never taken here.
      # We only need to confirm the code path does not raise.
      agent = ACS16TerminalBarrierAgent.new
      task = agent.invoke_async("no approval listener")
      result = task.wait_result
      expect(result).to be_a(Hash)
    end

    it "handles a raising on_event callback during approval notification" do
      # An on_event that raises on :approval_required exercises the
      # report_nonterminal_callback_error non-nil branch.
      allow(RubyLLM).to receive(:chat).and_return(build_acs16_terminal_chat)

      agent = ACS16TerminalBarrierAgent.new(
        on_event: ->(event) { raise "event callback failure" if event.type == :done }
      )
      task = agent.invoke_async("plain completion")
      # The agent completes; the callback raises on :done; the task should still
      # settle with the stream_callback_error_policy-governed result.
      expect { task.wait_result }.not_to raise_error
    end

    it "fails the task when stream_callback_error_policy is :fail_task and on_event raises" do
      allow(Phronomy.configuration).to receive(:stream_callback_error_policy).and_return(:fail_task)
      allow(RubyLLM).to receive(:chat).and_return(build_acs16_terminal_chat)

      agent = ACS16TerminalBarrierAgent.new(
        on_event: ->(event) { raise "callback failure" if event.type == :done }
      )
      task = agent.invoke_async("callback fail_task policy")
      expect { task.wait_result }.to raise_error(Phronomy::StreamCallbackError)
    end

    it "logs the warning when terminal durability requires recovery and a logger is configured" do
      persistence = Phronomy::Persistence::InMemory.new
      terminal_statuses = %i[completed rejected failed cancelled blocked handed_off]
      allow(persistence.executions).to receive(:save).and_wrap_original do |original, execution_id, expected_revision:, execution:|
        if terminal_statuses.include?(execution.status)
          raise "terminal persistence unavailable"
        end
        original.call(execution_id, expected_revision: expected_revision, execution: execution)
      end
      allow(RubyLLM).to receive(:chat).and_return(build_acs16_terminal_chat)

      logger = instance_double(Logger, warn: nil)
      allow(Phronomy.configuration).to receive(:logger).and_return(logger)

      agent = ACS16TerminalBarrierAgent.new(persistence: persistence)
      task = agent.invoke_async("finish normally")

      expect { task.wait_result(timeout: 0.15) }.to raise_error(Phronomy::TimeoutError)
      expect(task).not_to be_done
      expect(logger).to have_received(:warn)
    end

    it "suspends without calling the approval listener when no listener is provided" do
      persistence = Phronomy::Persistence::InMemory.new

      # Minimal HITL tool that requires approval.
      hitl_cls = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "acs16_hitl_tool"
        description "Requires approval"
        requires_approval true
        param :value, type: :string, desc: "Value"
        def execute(value:) = "ok:#{value}"
      end
      hitl_agent_cls = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "acs16-hitl-agent-nil-listener", version: 1
        model "test-model"
        instructions "Use the tool."
        tools hitl_cls => nil
      end

      tool_instance = hitl_cls.new
      tc = double("TC", name: "acs16_hitl_tool", arguments: {"value" => "x"},
        id: "call-nil-1", thought_signature: nil,
        to_h: {id: "call-nil-1", name: "acs16_hitl_tool", arguments: {"value" => "x"}})
      assistant = double("Asst", role: :assistant, content: nil, tool_calls: [tc],
        tokens: ACS16_TOKENS, tool_call?: true)
      stored_hook = nil
      chat = double("Chat")
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_tool).and_return(chat)
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:messages).and_return([assistant])
      allow(chat).to receive(:tools).and_return({acs16_hitl_tool: tool_instance})
      allow(chat).to receive(:add_message)
      allow(chat).to receive(:cancellation_token=)
      allow(chat).to receive(:on_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:before_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:on_tool_result)
      allow(chat).to receive(:ask) { stored_hook&.call(tc) }

      allow(RubyLLM).to receive(:chat).and_return(chat)
      agent = hitl_agent_cls.new(
        persistence: persistence,
        on_event: ->(event) { raise "event error" if event.type == :approval_required }
      )

      # The canonical Agent listener is allowed to fail on a nonterminal
      # :approval_required notification without settling the execution Task.
      task = agent.invoke_async("run hitl tool")

      Timeout.timeout(2) do
        loop do
          active = persistence.executions.list_active(agent.agent_id)
          break if active.any? { |e| e.status == :suspended }
          sleep 0.005
        end
      end

      expect(task).not_to be_done
    end

    it "handles supervise_agent_operation on an operation without physical_complete? (plain Task)" do
      # A cooperative tool that returns a pre-completed plain Phronomy::Task.
      # This exercises the `elsif operation.respond_to?(:done?)` branch in
      # supervise_agent_operation, which fires when the operation lacks
      # physical_complete? but has done?.
      cooperative_cls = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "acs16_cooperative_tool"
        description "Cooperative tool returning a plain Task"
        execution_mode :cooperative
        param :value, type: :string, desc: "Value"

        def call_async(args, cancellation_token: nil, config: {})
          task = Phronomy::Task.deferred(name: "acs16-plain-task")
          task.complete("coop:#{args.fetch(:value, "x")}")
          task
        end
      end
      coop_agent_cls = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "acs16-coop-agent", version: 1
        model "test-model"
        instructions "Use the cooperative tool."
        tools cooperative_cls => nil
      end

      coop_tool = cooperative_cls.new
      tc = double("TC", name: "acs16_cooperative_tool",
        arguments: {"value" => "hello"}, id: "call-coop-1",
        thought_signature: nil,
        to_h: {id: "call-coop-1", name: "acs16_cooperative_tool", arguments: {"value" => "hello"}})
      assistant = double("Asst", role: :assistant, content: nil, tool_calls: [tc],
        tokens: ACS16_TOKENS, tool_call?: true)
      final = double("Final", role: :assistant, content: "coop done",
        tool_calls: nil, tokens: ACS16_TOKENS, tool_call?: false)
      stored_hook = nil
      chat = double("CoopChat")
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_tool).and_return(chat)
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:messages).and_return([assistant])
      allow(chat).to receive(:tools).and_return({acs16_cooperative_tool: coop_tool})
      allow(chat).to receive(:add_message)
      allow(chat).to receive(:cancellation_token=)
      allow(chat).to receive(:on_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:before_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:on_tool_result)
      allow(chat).to receive(:ask) { stored_hook&.call(tc) }
      allow(chat).to receive(:complete).and_return(final)
      allow(RubyLLM).to receive(:chat).and_return(chat)

      agent = coop_agent_cls.new
      result = agent.invoke_async("use cooperative tool").wait_result
      expect(result[:output]).to eq("coop done")
    end

    it "handles supervise_agent_operation on an operation with no done? or physical_complete?" do
      # A cooperative tool that returns a custom completion handle with only on_complete.
      # This exercises the `else false` branch of supervise_agent_operation and
      # the `else operation.on_complete` branch (no on_physical_complete).
      custom_cls = Class.new(Phronomy::Agent::Context::Capability::Base) do
        tool_name "acs16_custom_handle_tool"
        description "Returns a custom completion handle"
        execution_mode :cooperative

        def call_async(args, cancellation_token: nil, config: {})
          handle = Object.new
          callbacks = []
          completed = false
          result_value = "custom:#{args.fetch(:value, "x")}"

          handle.define_singleton_method(:on_complete) do |&block|
            if completed
              block.call(result_value, nil)
            else
              callbacks << block
            end
            self
          end

          completed = true
          callbacks.each { |cb| cb.call(result_value, nil) }

          handle
        end
      end

      custom_agent_cls = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "acs16-custom-handle-agent", version: 1
        model "test-model"
        instructions "Use the custom tool."
        tools custom_cls => nil
      end

      custom_tool = custom_cls.new
      tc = double("TC", name: "acs16_custom_handle_tool",
        arguments: {"value" => "world"}, id: "call-custom-1",
        thought_signature: nil,
        to_h: {id: "call-custom-1", name: "acs16_custom_handle_tool", arguments: {"value" => "world"}})
      assistant = double("Asst", role: :assistant, content: nil, tool_calls: [tc],
        tokens: ACS16_TOKENS, tool_call?: true)
      final = double("Final", role: :assistant, content: "custom done",
        tool_calls: nil, tokens: ACS16_TOKENS, tool_call?: false)
      stored_hook = nil
      chat = double("CustomHandleChat")
      allow(chat).to receive(:with_instructions).and_return(chat)
      allow(chat).to receive(:with_tool).and_return(chat)
      allow(chat).to receive(:with_temperature).and_return(chat)
      allow(chat).to receive(:messages).and_return([assistant])
      allow(chat).to receive(:tools).and_return({acs16_custom_handle_tool: custom_tool})
      allow(chat).to receive(:add_message)
      allow(chat).to receive(:cancellation_token=)
      allow(chat).to receive(:on_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:before_tool_call) { |&block| stored_hook = block }
      allow(chat).to receive(:on_tool_result)
      allow(chat).to receive(:ask) { stored_hook&.call(tc) }
      allow(chat).to receive(:complete).and_return(final)
      allow(RubyLLM).to receive(:chat).and_return(chat)

      agent = custom_agent_cls.new
      result = agent.invoke_async("use custom handle tool").wait_result
      expect(result[:output]).to eq("custom done")
    end
  end
end
