# frozen_string_literal: true

require "spec_helper"

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

      agent = ACS16TerminalBarrierAgent.new(persistence: persistence)
      events = Queue.new
      task = agent.invoke_async(
        "finish normally",
        on_event: ->(event) { events << event.type }
      )

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
end
