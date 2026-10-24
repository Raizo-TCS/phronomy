# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent.run_once lifetime" do
  let(:created) { [] }
  let(:on_create) { ->(_agent) {} }
  let(:requests) { [] }
  let(:responses) { [Phronomy::LLMAdapter::Response.new(content: "answer", finish_reason: :stop)] }
  let(:definition) do
    observed, setup = created, on_create
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "scoped-run-once", version: 1
      model "offline-model"

      define_method(:initialize) do |**options, &listener|
        super(**options, &listener)
        observed << {agent: self, store: persistence}
        setup.call(self)
      end
    end
  end

  before do
    captured, queue = requests, responses
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        response = queue.shift || raise("unexpected extra model call")
        raise response if response.is_a?(Exception)
        response
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def run_once(**options, &listener)
    Phronomy::Agent.run_once(definition: definition, input: "question", **options, &listener)
  end

  def expect_released
    expect(created.length).to eq(1)
    agent = created.first.fetch(:agent)
    expect(definition.get(agent.agent_id)).to be_nil
    expect { agent.transcript }.to raise_error(Phronomy::AgentUnloadedError)
  end

  it "releases the live owner, preserves records and leaves other owners usable" do
    other_class = Class.new(Phronomy::Agent::Base) { agent_definition id: "other-owner", version: 1 }
    other = other_class.create
    result = run_once
    expect(result.fetch(:output)).to eq("answer")
    expect_released
    store = created.first.fetch(:store)
    agent_id = created.first.fetch(:agent).agent_id
    expect(store.agents.load(agent_id).agent_id).to eq(agent_id)
    expect(store.executions.load(result.fetch(:execution_id)).status).to eq(:completed)
    other.add_knowledge("still usable")
    expect(other_class.get(other.agent_id)).to equal(other)
    expect(requests.length).to eq(1)
  end

  it "releases after a provider failure and preserves the original exception" do
    failure = Phronomy::LLMAdapter::TransportError.new("offline provider failure")
    responses.replace([failure])
    expect { run_once }.to raise_error { |error| expect(error).to equal(failure) }
    expect_released
    expect(requests.length).to eq(1)
  end

  it "releases after strict output validation fails without another model call" do
    schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]}
    expect { run_once(output_schema: schema, schema_delivery: :none) }
      .to raise_error(Phronomy::Agent::OutputError) { |error| expect(error.reason).to eq("invalid_json") }
    expect_released
    expect(requests.length).to eq(1)
    expect(requests.first.response_schema).to be_nil
  end

  it "releases a created owner after invocation option validation fails" do
    expect { run_once(schema_delivery: :none) }.to raise_error(ArgumentError)
    expect_released
    expect(requests).to be_empty
  end

  context "when release fails" do
    let(:cleanup_failure) { IOError.new("release check failed") }
    let(:on_create) { ->(agent) { allow(agent).to receive(:unload!).and_raise(cleanup_failure) } }

    it "retains the successful result and a scope that can retry release" do
      recovery = nil
      expect { run_once }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
        recovery = error.scope
        expect(error.result.fetch(:output)).to eq("answer")
        expect(error.primary_error).to be_nil
        expect(error.cause).to equal(cleanup_failure)
        expect(error.failures).to eq([{agent_id: created.first.fetch(:agent).agent_id, error: cleanup_failure}])
      }
      agent = created.first.fetch(:agent)
      expect(definition.get(agent.agent_id)).to equal(agent)
      allow(agent).to receive(:unload!).and_call_original
      expect(recovery.release!).to be(true)
      expect(recovery.release!).to be(false)
      expect_released
      expect(requests.length).to eq(1)
    end

    it "preserves both the invocation error and the cleanup failure" do
      primary = Phronomy::LLMAdapter::TransportError.new("provider failed first")
      responses.replace([primary])
      recovery = nil
      expect { run_once }.to raise_error(Phronomy::Agent::ScopeCleanupError) { |error|
        recovery = error.scope
        expect(error.primary_error).to equal(primary)
        expect(error.cause).to equal(primary)
        expect(error.result).to be_nil
        expect(error.failures.map { |entry| entry.fetch(:error) }).to eq([cleanup_failure])
      }
      agent = created.first.fetch(:agent)
      expect(definition.get(agent.agent_id)).to equal(agent)
      allow(agent).to receive(:unload!).and_call_original
      recovery.release!
      expect_released
      expect(requests.length).to eq(1)
    end
  end

  [:report, :fail_task].each do |policy|
    it "keeps the #{policy} listener-error policy and releases after terminal delivery" do
      Phronomy.configuration.stream_callback_error_policy = policy
      listener = ->(event) { raise IOError, "listener failed" if event.type == :done }
      if policy == :fail_task
        expect { run_once(on_event: listener) }.to raise_error(Phronomy::StreamCallbackError)
      else
        expect(run_once(on_event: listener).fetch(:output)).to eq("answer")
      end
      expect_released
      expect(requests.length).to eq(1)
    end
  end

  it "keeps ownership while approval is pending and releases only after completion" do
    count = 0
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "protected_read"
      description "An approved offline read"
      requires_approval true
      define_method(:execute) {
        count += 1
        "read"
      }
    end
    definition.tools tool => nil
    responses.unshift(Phronomy::LLMAdapter::Response.new(
      tool_calls: [Phronomy::Tool::CallRequest.new(id: "read-1", name: "protected_read", arguments: {})],
      finish_reason: :tool_calls
    ))
    approvals = Queue.new
    caller_thread = Thread.new do
      run_once(on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
    end
    approval = approvals.pop(timeout: 3)
    expect(approval).not_to be_nil
    agent = created.first.fetch(:agent)
    expect(caller_thread).to be_alive
    expect(definition.get(agent.agent_id)).to equal(agent)
    expect(count).to eq(0)
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    approval_task = agent.approve_async(approval.execution_id, approval_request_id: approval.id, approved: true)
    expect(approval_task.wait_result(timeout: 3).fetch(:output)).to eq("answer")
    expect(caller_thread.join(3)).not_to be_nil
    expect(caller_thread.value.fetch(:output)).to eq("answer")
    expect_released
    expect(count).to eq(1)
    expect(requests.length).to eq(2)
  ensure
    if caller_thread&.alive?
      Phronomy.reset_runtime!
      caller_thread.join(3)
    end
  end

  it "rejects EventLoop entry before allocating storage or an owner" do
    klass = definition
    completed = Phronomy::TaskResult.deferred
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      Phronomy::Agent.run_once(definition: klass, input: "question")
      completed.complete(:unexpected)
    rescue => error
      completed.fail(error)
    end
    expect(Phronomy::PersistenceComposition).not_to receive(:agent)
    Phronomy::Agent::ExecutionEnvironment.current.registry.post(Struct.new(:coordinator).new(handler), completion: completed)
    expect { completed.wait_result(timeout: 3) }.to raise_error(Phronomy::EventLoopReentrancyError)
    expect(created).to be_empty
    expect(requests).to be_empty
  end
end
