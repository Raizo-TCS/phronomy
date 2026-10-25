# frozen_string_literal: true

require "spec_helper"
require "weakref"

RSpec.describe "Agent Tool child lifetime" do
  let(:created) { [] }
  let(:requests) { [] }
  let(:responses) { [Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop)] }
  let(:gate) { nil }
  let(:on_create) { ->(_agent) {} }
  let(:listener) { nil }
  let(:definition) do
    observed, setup, observer = created, on_create, listener
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "tool-lifetime", version: 1
      model "offline-model"
      define_method(:initialize) do |**options, &block|
        options = options.merge(on_event: observer) if observer
        super(**options, &block)
        observed << {agent: self, store: persistence}
        setup.call(self)
      end
    end
  end
  let(:tool_class) { Phronomy::Tools::Agent.from_agent(definition) }
  let(:tool) { tool_class.new }

  before do
    captured, queue, blocker = requests, responses, gate
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        if blocker
          blocker.fetch(:entered) << true
          blocker.fetch(:release).pop(timeout: 5)
        end
        response = queue.shift || raise("unexpected extra model call")
        raise response if response.is_a?(Exception)
        response
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def invoke(mode)
    args = {"input" => "question"}
    (mode == :sync) ? tool.call(args) : tool.call_async(args).wait_result(timeout: 5)
  end

  def expect_released
    expect(created.length).to eq(1)
    child, store = created.first.values_at(:agent, :store)
    expect(definition.get(child.agent_id)).to be_nil
    expect { child.transcript }.to raise_error(Phronomy::AgentUnloadedError)
    expect(store.agents.load(child.agent_id).agent_id).to eq(child.agent_id)
  end

  def on_loop(&action)
    result = Phronomy::TaskResult.deferred
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      result.complete(action.call)
    rescue => error
      result.fail(error)
    end
    Phronomy::Agent::ExecutionEnvironment.current.registry.post(Struct.new(:coordinator).new(handler), completion: result)
    result.wait_result(timeout: 3)
  end

  [:sync, :async].each do |mode|
    it "releases after #{mode} success and preserves records and other owners" do
      other_class = Class.new(Phronomy::Agent::Base) { agent_definition id: "unrelated", version: 1 }
      other = other_class.create
      expect(invoke(mode)).to eq("answer")
      expect_released
      other.add_knowledge("still usable")
      expect(other_class.get(other.agent_id)).to equal(other)
      expect(requests.length).to eq(1)
    end

    it "releases after #{mode} provider failure without replaying it" do
      failure = Phronomy::LLMAdapter::TransportError.new("offline failure")
      responses.replace([failure])
      expect { invoke(mode) }.to raise_error(Phronomy::ToolError) { |error| expect(error.cause).to equal(failure) }
      expect_released
      expect(requests.length).to eq(1)
    end

    it "keeps #{mode} suppression policy while still releasing" do
      tool_class.on_error :suppress
      responses.replace([RuntimeError.new("offline failure")])
      expect(invoke(mode)).to include("Tool error suppressed")
      expect_released
    end

    it "releases after #{mode} synchronous invocation startup failure" do
      failure = ArgumentError.new("invalid invocation")
      allow_any_instance_of(definition).to receive(:invoke_async).and_raise(failure)
      expect { invoke(mode) }.to raise_error(Phronomy::ToolError) { |error| expect(error.cause).to equal(failure) }
      expect_released
      expect(requests).to be_empty
    end

    it "releases after #{mode} output conversion failure" do
      failure = IOError.new("output conversion")
      value = Object.new
      value.define_singleton_method(:to_s) { raise failure }
      allow_any_instance_of(definition).to receive(:invoke_async).and_return(Phronomy::TaskResult.completed({output: value}))
      expect { invoke(mode) }.to raise_error(Phronomy::ToolError) { |error| expect(error.cause).to equal(failure) }
      expect_released
      expect(requests).to be_empty
    end
  end

  it "does not accumulate owners across repeated sync and async calls" do
    responses.replace(Array.new(6) { Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop) })
    3.times { expect(invoke(:sync)).to eq("answer") }
    3.times { expect(invoke(:async)).to eq("answer") }
    expect(created.length).to eq(6)
    expect(created.map { |entry| entry.fetch(:store).object_id }.uniq.length).to eq(6)
    expect(created.all? { |entry| definition.get(entry.fetch(:agent).agent_id).nil? }).to be(true)
  end

  it "rejects invalid arguments and pre-cancelled requests before child creation" do
    expect(tool.call_async({}).wait_result).to include("Schema validation failed")
    token = Phronomy::Concurrency::CancellationToken.new.cancel!
    expect { tool.call_async({"input" => "question"}, cancellation_token: token).wait_result }
      .to raise_error(Phronomy::CancellationError)
    expect(created).to be_empty
    expect(requests).to be_empty
  end

  it "captures invalid invocation handles and still releases the child" do
    allow_any_instance_of(definition).to receive(:invoke_async).and_return(nil)
    expect { invoke(:async) }.to raise_error(Phronomy::ToolError) { |error| expect(error.cause).to be_a(TypeError) }
    expect_released
  end

  it "rejects invalid config before creating a child" do
    expect { tool.call_async({"input" => "question"}, config: "invalid").wait_result }.to raise_error(Phronomy::ToolError)
    expect(created).to be_empty
  end

  it "rejects synchronous EventLoop entry before acquiring a store" do
    current = tool
    expect(Phronomy::Agent::DefaultPersistence).not_to receive(:build)
    expect { on_loop { current.execute(input: "question") } }.to raise_error(Phronomy::EventLoopReentrancyError)
    expect(created).to be_empty
  end

  it "releases the child in actual parent dispatch with only one offload worker" do
    Phronomy.configuration.offload_pool_size = 1
    wrapped = tool_class
    parent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "tool-lifetime-parent", version: 1
      model "offline-model"
      tools wrapped => nil
    end
    responses.replace([
      Phronomy::LLMAdapter::Response.new(tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "child-call", name: tool.name, arguments: {input: "question"})
      ], finish_reason: :tool_calls),
      Phronomy::LLMAdapter::Response.new(content: "child answer", finish_reason: :stop),
      Phronomy::LLMAdapter::Response.new(content: "parent answer", finish_reason: :stop)
    ])
    parent = parent_class.create
    expect(parent.invoke_async("delegate").wait_result(timeout: 5).fetch(:output)).to eq("parent answer")
    expect_released
    expect(parent_class.get(parent.agent_id)).to equal(parent)
    expect(requests.length).to eq(3)
  end

  context "when cleanup fails" do
    let(:cleanup_failure) { IOError.new("release failed") }
    let(:on_create) { ->(agent) { allow(agent).to receive(:unload_async).and_return(Phronomy::TaskResult.failed(cleanup_failure)) } }
    let(:log) { double("logger", error: nil, warn: nil, debug: nil, info: nil) }

    before { Phronomy.configuration.logger = log }

    [:sync, :async].each do |mode|
      [false, true].each do |failed|
        it "preserves #{mode} #{failed ? "failure" : "success"} and allows release-only retry" do
          primary = Phronomy::LLMAdapter::TransportError.new("primary") if failed
          responses.replace([primary]) if failed
          tool_class.on_error :suppress
          error = nil
          expect { invoke(mode) }.to raise_error(Phronomy::Tools::Agent::CleanupError) { |raised| error = raised }
          child = created.first.fetch(:agent)
          expect(error.child_agent).to equal(child)
          expect(error.agent_id).to eq(child.agent_id)
          expect(error.code).to eq("tool.agent_cleanup_failed")
          expect(error.result).to eq(failed ? nil : "answer")
          expect(error.primary_error).to equal(primary)
          expect(error.cleanup_error).to equal(cleanup_failure)
          expect(error.cause).to equal(primary || cleanup_failure)
          expect(log).to have_received(:error).with(a_string_including(child.agent_id, "tool.agent_cleanup_failed")).once
          expect(definition.get(child.agent_id)).to equal(child)
          allow(child).to receive(:unload_async).and_call_original
          expect(error.child_agent.unload_async.wait_result(timeout: 3)).to be(true)
          expect_released
          expect(requests.length).to eq(1)
        end
      end
    end

    it "preserves the cleanup error when diagnostic logging raises" do
      allow(log).to receive(:error).and_raise(IOError, "logger failed")
      expect { invoke(:async) }.to raise_error(Phronomy::Tools::Agent::CleanupError) { |error|
        expect(error.cleanup_error).to equal(cleanup_failure)
      }
    end
  end

  context "with active physical work" do
    let(:gate) { {entered: Queue.new, release: Queue.new} }

    [:observer, :token].each do |kind|
      it "keeps #{kind} cancellation safe and releases after physical completion" do
        token = Phronomy::Concurrency::CancellationToken.new
        task = tool.call_async({"input" => "question"}, cancellation_token: token)
        expect(gate.fetch(:entered).pop(timeout: 3)).to be(true)
        child = created.first.fetch(:agent)
        (kind == :observer) ? task.cancel! : token.cancel!
        expect(task.physical_complete?).to be(false)
        expect { child.unload! }.to raise_error(Phronomy::AgentBusyError)
        physical = Queue.new
        task.on_physical_complete { physical << true }
        gate.fetch(:release) << true
        expect(physical.pop(timeout: 5)).to be(true)
        expect_released
        expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::CancellationError)
        expect(requests.length).to eq(1)
      ensure
        gate.fetch(:release) << true
      end
    end

    it "reports cleanup failure after observer cancellation" do
      messages = Queue.new
      logger = double("logger", warn: nil, debug: nil, info: nil)
      allow(logger).to receive(:error) { |message| messages << message }
      Phronomy.configuration.logger = logger
      task = tool.call_async({"input" => "question"})
      gate.fetch(:entered).pop(timeout: 3)
      child = created.first.fetch(:agent)
      allow(child).to receive(:unload_async).and_return(Phronomy::TaskResult.failed(IOError.new("cleanup")))
      task.cancel!
      physical = Queue.new
      task.on_physical_complete { physical << true }
      gate.fetch(:release) << true
      physical.pop(timeout: 5)
      expect(messages.pop(timeout: 3)).to include(child.agent_id, "tool.agent_cleanup_failed", "cleanup")
      expect(task.status).to eq(:cancelled)
      expect(definition.get(child.agent_id)).to equal(child)
      allow(child).to receive(:unload_async).and_call_original
      expect(child.unload_async.wait_result(timeout: 3)).to be(true)
      expect(requests.length).to eq(1)
    ensure
      gate.fetch(:release) << true
    end

    it "keeps parallel children independent while one is cancelled" do
      responses.replace(Array.new(2) { Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop) })
      first_token = Phronomy::Concurrency::CancellationToken.new
      first = tool.call_async({"input" => "one"}, cancellation_token: first_token)
      gate.fetch(:entered).pop(timeout: 3)
      second = tool.call_async({"input" => "two"})
      gate.fetch(:entered).pop(timeout: 3)
      first_token.cancel!
      2.times { gate.fetch(:release) << true }
      expect { first.wait_result(timeout: 5) }.to raise_error(Phronomy::CancellationError)
      expect(second.wait_result(timeout: 5)).to eq("answer")
      expect(created.all? { |entry| definition.get(entry.fetch(:agent).agent_id).nil? }).to be(true)
    ensure
      2.times { gate.fetch(:release) << true }
    end
  end

  context "with approval pending" do
    let(:approvals) { Queue.new }
    let(:listener) { ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required } }

    it "retains the child without auto-approval and releases after accepted approval finishes" do
      count = 0
      protected_tool = Class.new(Phronomy::Tool::Base) do
        tool_name "protected_read"
        description "Read after explicit approval"
        requires_approval true
        define_method(:execute) {
          count += 1
          "read"
        }
      end
      definition.tools protected_tool => nil
      responses.unshift(Phronomy::LLMAdapter::Response.new(tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "read", name: "protected_read", arguments: {})
      ], finish_reason: :tool_calls))
      task = tool.call_async({"input" => "question"})
      approval = approvals.pop(timeout: 3)
      child = created.first.fetch(:agent)
      expect(task).not_to be_done
      expect(count).to eq(0)
      expect { child.unload! }.to raise_error(Phronomy::AgentBusyError)
      child.approve_async(approval.execution_id, approval_request_id: approval.id, approved: true).wait_result(timeout: 5)
      expect(task.wait_result(timeout: 5)).to eq("answer")
      expect_released
      expect(count).to eq(1)
      expect(requests.length).to eq(2)
    end
  end

  it "does not retain a released child through a completed Tool handle" do
    reference, task = Thread.new do
      result = tool.call_async({"input" => "question"})
      result.wait_result(timeout: 5)
      child = created.pop.fetch(:agent)
      [WeakRef.new(child), result]
    end.value
    on_loop { true }
    3.times { GC.start }
    expect(reference.weakref_alive?).to be_falsey
    expect(task.wait_result).to eq("answer")
  end

  it "does not retain earlier children across completed Tool calls" do
    responses.replace(Array.new(6) { Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop) })
    references, tasks = Thread.new do
      Array.new(6) do
        result = tool.call_async({"input" => "question"})
        result.wait_result(timeout: 5)
        child = created.pop.fetch(:agent)
        [WeakRef.new(child), result]
      end.transpose
    end.value
    on_loop { true }
    3.times { GC.start }
    expect(references.none?(&:weakref_alive?)).to be(true)
    expect(tasks.map(&:wait_result)).to eq(Array.new(6, "answer"))
  end

  it "applies each result transformation once after release" do
    stages = []
    first = Phronomy::Tool::Operation.with_result_transform(tool_class) do |value, _name, _args|
      stages << :first
      expect_released
      "#{value}|first"
    end
    second = Phronomy::Tool::Operation.with_result_transform(first) do |value, _name, _args|
      stages << :second
      "#{value}|second"
    end
    expect(second.new.call_async({"input" => "question"}).wait_result(timeout: 5)).to eq("answer|first|second")
    expect(stages).to eq([:first, :second])
  end

  context "with an unrelated accepted operation" do
    let(:leases) { [] }
    let(:on_create) { ->(agent) { leases << agent.send(:__acquire_operation!) } }

    it "does not release another operation when acknowledging terminal waiters" do
      failure = nil
      expect { invoke(:async) }.to raise_error(Phronomy::Tools::Agent::CleanupError) { |error| failure = error }
      expect(failure.result).to eq("answer")
      expect(failure.cleanup_error).to be_a(Phronomy::AgentBusyError)
      child = created.first.fetch(:agent)
      expect(definition.get(child.agent_id)).to equal(child)
      leases.each(&:release)
      expect(child.unload_async.wait_result(timeout: 3)).to be(true)
      expect_released
      expect(requests.length).to eq(1)
    ensure
      leases.each(&:release)
    end
  end

  context "when shutdown overlaps an accepted release" do
    let(:entered) { Queue.new }
    let(:release) { Queue.new }
    let(:on_create) do
      ->(agent) {
        allow(agent).to receive(:unload_async).and_wrap_original do |original|
          allow(agent.persistence).to receive(:transaction).and_wrap_original do |transaction, &block|
            entered << true
            release.pop(timeout: 5)
            transaction.call(&block)
          end
          original.call
        end
      }
    end

    it "drains cleanup in the original Runtime without creating another owner" do
      task = tool.call_async({"input" => "question"})
      entered.pop(timeout: 3)
      child = created.first.fetch(:agent)
      runtime = Phronomy::Runtime.instance
      draining = Queue.new
      ownership = child.__execution_environment.ownership
      allow(ownership).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
        draining << true
        original.call(deadline)
      end
      shutdown = Thread.new { runtime.shutdown(timeout: 3) }
      draining.pop(timeout: 3)
      expect(task).not_to be_done
      expect(task.physical_complete?).to be(false)
      release << true
      expect(task.wait_result(timeout: 3)).to eq("answer")
      expect(shutdown.join(3)).not_to be_nil
      expect(shutdown.value.cleanup_complete?).to be(true)
      expect(Phronomy::Runtime.instance).to equal(runtime)
      expect { child.transcript }.to raise_error(Phronomy::AgentUnloadedError)
      expect(requests.length).to eq(1)
    ensure
      release << true
      shutdown&.join(3)
    end
  end
end
