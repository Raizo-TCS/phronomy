# frozen_string_literal: true

require "spec_helper"
require_relative "../multi_agent/support/durable_coordination"

RSpec.describe "Agent transcript Message reads" do
  include_context "durable coordination runtime"
  let(:agent) { worker.create(persistence: store.agent) }

  def on_loop(&action)
    completion = Phronomy::TaskResult.deferred
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completion.complete(action.call)
    rescue => error
      completion.fail(error)
    end
    agent.__execution_environment.registry.post(Struct.new(:coordinator).new(handler), completion: completion)
    completion.wait_result(timeout: 3)
  end

  def messages(values)
    values.map(&:to_h)
  end

  it "returns empty immutable messages and retains the original Journal API" do
    expect(agent.transcript_messages).to eq([])
    expect(agent.transcript_messages).to be_frozen
    expect(agent.transcript).to eq([])
  end

  it "matches result messages and a fresh Runtime read without another request or write" do
    LLMStub.activate(responses: ["answer"])
    result = agent.invoke('{"looks":"like JSON"}')
    before = store.snapshot
    read = agent.transcript_messages_async.wait_result(timeout: 3)
    expect(messages(read)).to eq(messages(result[:messages]))
    expect(read.first.content).to eq('{"looks":"like JSON"}')
    expect(read).to be_frozen
    expect(read).to all(be_frozen)
    expect(agent.transcript.first).to be_a(Phronomy::Agent::JournalRecord)
    expect(Marshal.dump(store.snapshot)).to eq(Marshal.dump(before))
    id = agent.agent_id
    restored = reboot(before)
    llm = LLMStub.activate(responses: ["must not call"])
    loaded = worker.load(id, persistence: restored.agent)
    expect(messages(loaded.transcript_messages)).to eq(messages(result[:messages]))
    expect(llm.calls).to be_empty
    expect(Marshal.dump(restored.snapshot)).to eq(Marshal.dump(before))
  end

  it "keeps Tool calls, empty assistant content, results and opaque metadata" do
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "read_value"
      description "A fixed read"
      def execute = "value"
    end
    worker.tools tool => nil
    responses = [Phronomy::LLMAdapter::Response.new(content: nil, finish_reason: :tool_calls,
      tool_calls: [Phronomy::Tool::CallRequest.new(id: "call-1", name: "read_value", arguments: {}, metadata: {"opaque" => "call-data"})],
      metadata: {"opaque" => {"continuation" => "provider-data"}}),
      Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop)]
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) { |_request, cancellation_token:| responses.shift || raise("unexpected call") }
    end.new
    Phronomy.configure { |c| c.llm_adapter = adapter }
    result = agent.invoke("q")
    read = agent.transcript_messages
    expect(messages(read)).to eq(messages(result[:messages]))
    expect(read.map(&:role)).to eq(%i[user assistant tool assistant])
    expect(read[1].content).to be_nil
    expect(read[1].tool_calls.first.metadata["opaque"]).to eq("call-data")
    expect(read[1].metadata.dig("opaque", "continuation")).to eq("provider-data")
    expect(read[2].tool_call_id).to eq("call-1")
    expect(read[2].content).to eq("value")
  end

  [nil, "", {"answer" => "structured"}, [{"type" => "text", "text" => "part"}]].each do |content|
    it "retains legitimate #{content.class} assistant content without a text-only filter" do
      adapter = Class.new(Phronomy::LLMAdapter::Base) do
        define_method(:perform_complete) do |_request, cancellation_token:|
          Phronomy::LLMAdapter::Response.new(content: content, finish_reason: :stop)
        end
      end.new
      Phronomy.configure { |c| c.llm_adapter = adapter }
      result = agent.invoke("q")
      expect(messages(agent.transcript_messages)).to eq(messages(result[:messages]))
      expect(agent.transcript_messages.last.content).to eq(content)
    end
  end

  it "honors transcript generations without including Knowledge" do
    agent.add_knowledge("not a conversation")
    llm = LLMStub.activate(responses: ["old", "new"])
    agent.invoke("old question")
    agent.clear_transcript!
    expect(agent.transcript_messages).to be_empty
    result = agent.invoke("new question")
    expect(messages(agent.transcript_messages)).to eq(messages(result[:messages]))
    expect(agent.transcript_messages.map(&:content)).to eq(["new question", "new"])
    expect(llm.calls.length).to eq(2)
  end

  it "holds ownership after logical cancellation until the content read physically finishes" do
    LLMStub.activate(responses: ["answer"])
    agent.invoke("q")
    entered, release, finished = Queue.new, Queue.new, Queue.new
    store.before_io = ->(operation) {
      if operation == :fetch
        entered << true
        release.pop(timeout: 3)
      end
    }
    task = agent.transcript_messages_async
    task.on_physical_complete { finished << true }
    entered.pop(timeout: 3)
    task.cancel!
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    store.before_io = nil
    release << true
    finished.pop(timeout: 3)
    expect(agent.unload!).to be(true)
  ensure
    store.before_io = nil
    release << true if release
  end

  it "rejects synchronous EventLoop reads and completes async reads off EventLoop" do
    LLMStub.activate(responses: ["answer"])
    expected = agent.invoke("q")[:messages]
    expect { on_loop { agent.transcript_messages } }.to raise_error(Phronomy::EventLoopReentrancyError)
    task = on_loop { agent.transcript_messages_async }
    expect(messages(task.wait_result(timeout: 3))).to eq(messages(expected))
  end

  it "propagates content failures rather than returning an empty or partial transcript" do
    LLMStub.activate(responses: ["answer"])
    agent.invoke("q")
    ref = agent.transcript.last.content_ref
    allow(store.agent.contents).to receive(:fetch).and_call_original
    allow(store.agent.contents).to receive(:fetch).with(ref).and_raise(Phronomy::ContentStore::IntegrityError, "invalid stored bytes")
    expect { agent.transcript_messages }.to raise_error(Phronomy::ContentStore::IntegrityError)
    expect { agent.transcript_messages_async.wait_result }.to raise_error(Phronomy::ContentStore::IntegrityError)
    expect(agent.unload!).to be(true)
  end

  it "keeps the selected generation consistent when clear overlaps content restoration" do
    LLMStub.activate(responses: ["answer"])
    expected = agent.invoke("old")[:messages]
    entered, release = Queue.new, Queue.new
    store.before_io = ->(operation) {
      if operation == :fetch
        entered << true
        release.pop(timeout: 3)
      end
    }
    task = agent.transcript_messages_async
    entered.pop(timeout: 3)
    store.before_io = nil
    agent.clear_transcript!
    release << true
    expect(messages(task.wait_result(timeout: 3))).to eq(messages(expected))
    expect(agent.transcript_messages).to be_empty
  ensure
    store.before_io = nil
    release << true if release
  end

  it "preserves unloaded failures for both entry points" do
    agent.unload!
    expect { agent.transcript_messages }.to raise_error(Phronomy::AgentUnloadedError)
    expect { agent.transcript_messages_async.wait_result }.to raise_error(Phronomy::AgentUnloadedError)
  end
end
