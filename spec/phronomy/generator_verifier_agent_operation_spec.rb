# frozen_string_literal: true

require "spec_helper"

RSpec.describe "GeneratorVerifier public Agent connection" do
  let(:operation_class) { Phronomy::GeneratorVerifier.const_get(:AgentOperation) }
  let(:tasks) { [] }
  let(:agents) { [] }
  let(:agent_class) do
    instances = agents
    pending = tasks
    Class.new do
      attr_reader :listener, :inputs

      define_method(:initialize) do |on_event:|
        @listener = on_event
        @inputs = []
        instances << self
      end

      define_method(:invoke_async) do |input|
        @inputs << input
        task = Phronomy::TaskResult.new(name: input)
        pending << task
        task
      end
    end
  end
  let(:operation) { operation_class.new(agent_class) }

  def event(type, payload = {})
    Phronomy::Agent::StreamEvent.new(type: type, payload: payload)
  end

  it "constructs one Agent with a fixed listener and observes each call's result" do
    first = []
    second = []
    operation.start("first", listener: first.method(:<<))
    # A terminal notification alone is not a per-call result contract.
    agents.first.listener.call(event(:done, {output: "notification"}))
    expect(first).to be_empty
    tasks.first.complete(output: "first result")
    operation.start("second", listener: second.method(:<<))
    tasks.last.complete(output: "second result")

    expect(agents.length).to eq(1)
    expect(agents.first.inputs).to eq(%w[first second])
    expect(first.map(&:payload)).to eq([{output: "first result"}])
    expect(second.map(&:payload)).to eq([{output: "second result"}])
  end

  it "handles a result settled before invoke_async returns" do
    klass = Class.new do
      def initialize(on_event:)
      end

      def invoke_async(input)
        Phronomy::TaskResult.completed({output: input})
      end
    end
    received = []
    operation_class.new(klass).start("inline", listener: received.method(:<<))
    expect(received.map(&:payload)).to eq([{output: "inline"}])
  end

  [[:error, RuntimeError], [:timeout, Phronomy::TimeoutError], [:cancelled, Phronomy::CancellationError]].each do |type, klass|
    it "preserves the #{type} exception and call association" do
      received = []
      error = klass.new("original")
      operation.start("request", listener: received.method(:<<))
      tasks.first.fail(error)
      expect(received.length).to eq(1)
      expect(received.first.type).to eq(type)
      expect(received.first.payload[:error]).to equal(error)
    end
  end

  it "routes approval while the originating TaskResult is still pending" do
    received = []
    operation.start("request", listener: received.method(:<<))
    approval = event(:approval_required, {request: :approval})
    agents.first.listener.call(approval)
    expect(received).to eq([approval])
    expect(tasks.first).not_to be_done
    tasks.first.complete(output: "resumed")
    expect(received.map(&:type)).to eq([:approval_required, :done])
  end

  it "keeps an overlapping busy rejection separate from the active approval" do
    first = []
    second = []
    operation.start("first", listener: first.method(:<<))
    operation.start("second", listener: second.method(:<<))
    busy = Phronomy::AgentBusyError.new("busy")
    tasks.last.fail(busy)
    approval = event(:approval_required)
    agents.first.listener.call(approval)
    expect(first).to eq([approval])
    expect(second.first.payload[:error]).to equal(busy)
    expect(tasks.first).not_to be_done
  end

  it "retains a queued submission admitted after the previous request completes" do
    first = []
    second = []
    operation.start("first", listener: first.method(:<<))
    operation.start("second", listener: second.method(:<<))
    tasks.first.complete(output: "first")
    approval = event(:approval_required)
    agents.first.listener.call(approval)
    expect(first.map(&:type)).to eq([:done])
    expect(second).to eq([approval])
  end

  it "does not misroute a late incarnation terminal notification to a later call" do
    first = []
    second = []
    operation.start("first", listener: first.method(:<<))
    tasks.first.complete(output: "first")
    operation.start("second", listener: second.method(:<<))
    agents.first.listener.call(event(:done, {output: "late"}))
    agents.first.listener.call(event(:error, {error: RuntimeError.new("late")}))
    tasks.last.complete(output: "second")
    expect(first.map(&:payload)).to eq([{output: "first"}])
    expect(second.map(&:payload)).to eq([{output: "second"}])
  end

  it "releases a synchronous start failure without changing the exception" do
    received = []
    operation
    error = RuntimeError.new("start")
    allow(agents.first).to receive(:invoke_async).and_raise(error)
    expect { operation.start("first", listener: received.method(:<<)) }
      .to raise_error { |raised| expect(raised).to equal(error) }
    agents.first.listener.call(event(:approval_required))
    expect(received).to be_empty
  end

  it "does not reinterpret a handoff as a generation completion" do
    received = []
    operation.start("request", listener: received.method(:<<))
    tasks.first.complete(handoff_request: :handoff)
    expect(received).to be_empty
  end

  it "leaves malformed result interpretation to the domain receiver" do
    failures = []
    workflow = double("workflow")
    allow(workflow).to receive(:signal) { |**values| failures << values }
    receiver = Phronomy::GeneratorVerifier.const_get(:AgentResultReceiver).new(
      draft_result_parser: ->(text) { text }, review_result_parser: ->(text) { text }
    )
    listener = receiver.draft_listener(workflow: workflow, workflow_instance_id: "workflow", request_id: "request")
    operation.start("request", listener: listener)
    tasks.first.complete("malformed")
    expect(failures.length).to eq(1)
    expect(failures.first[:event]).to eq(:draft_failed)
    expect(failures.first[:payload][:request_id]).to eq("request")
    expect(failures.first[:payload][:error]).to be_a(TypeError)
  end

  it "does not expose the removed execution-local Agent event sink" do
    expect(Phronomy::Agent::Base.private_instance_methods).not_to include(:__invoke_async_with_event_sink)
  end
end
