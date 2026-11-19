# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Direct Orchestrator child lifetime" do
  let(:created) { [] }
  let(:requests) { [] }
  let(:setup) { ->(_agent) {} }
  let(:respond) { ->(_request) { Phronomy::LLMAdapter::Response.new(content: "answer") } }
  let(:worker) do
    observed, prepare = created, setup
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "direct-child-lifetime", version: 1
      model "offline-child"
      define_method(:initialize) do |**options, &block|
        super(**options, &block)
        observed << self
        prepare.call(self)
      end
    end
  end
  let(:parent) do
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "direct-parent-lifetime", version: 1
    end.create
  end

  before do
    observed, response = requests, respond
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        observed << request
        response.call(request)
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def task(**options)
    {agent: worker, input: "question", **options}
  end

  def expect_released(agents = created)
    expect(agents).not_to be_empty
    agents.each do |agent|
      expect(agent.class.get(agent.agent_id)).to be_nil
      expect { agent.transcript }.to raise_error(Phronomy::AgentUnloadedError)
      expect(agent.persistence.agents.load(agent.agent_id).agent_id).to eq(agent.agent_id)
    end
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

  # Capture the production timeout callback instead of scheduling a wall-clock
  # timer, then deliver it on EventLoop after the required child starts.
  def controlled_execution_timeout
    callbacks = Queue.new
    expect(Phronomy::Execution).to receive(:after).once do |seconds, &callback|
      expect(seconds).to be_positive
      callbacks << callback
      -> {}
    end
    -> { on_loop(&callbacks.pop(true)) }
  end

  it "preserves successful subagent owners for explicit reuse and release" do
    result = parent.subagent(worker, "question")
    child = worker.get(result.fetch(:agent_id))
    expect(child).to equal(created.first)
    expect(child.invoke("follow-up").fetch(:output)).to eq("answer")
    expect(child.unload!).to be(true)
    expect_released
  end

  it "materializes serial children off EventLoop and retains returned owners" do
    owner = parent
    tasks = [task, task]
    pending = on_loop { owner.dispatch_parallel_async(*tasks, max_concurrency: 1, inherit_knowledge: false) }
    results = pending.wait_result(timeout: 5)
    expect(results.map { |result| result.fetch(:agent_id) }).to eq(created.map(&:agent_id))
    created.each { |child| expect(child.unload!).to be(true) }
    expect_released
  end

  context "when a child fails" do
    let(:failure) { RuntimeError.new("provider failed") }
    let(:respond) { ->(_request) { raise failure } }

    it "releases before skip returns nil without erasing durable records" do
      3.times { expect(parent.dispatch_parallel(task, on_error: :skip)).to eq([nil]) }
      expect(requests.length).to eq(3)
      expect_released
      expect(parent.unload!).to be(true)
    end

    it "preserves the original synchronous subagent failure" do
      expect { parent.subagent(worker, "question") }.to raise_error { |error| expect(error).to equal(failure) }
      expect_released
    end

    it "releases every successful sibling when raise hides their results" do
      success = Class.new(worker) do
        agent_definition id: "direct-successful-sibling", version: 1
        model "success"
      end
      allow(respond).to receive(:call).and_wrap_original do |original, request|
        (request.model_config["model"] == "success") ? Phronomy::LLMAdapter::Response.new(content: "kept only if returned") : original.call(request)
      end
      expect {
        parent.dispatch_parallel(task(agent: success), task, task(agent: success), max_concurrency: 1)
      }.to raise_error { |error| expect(error).to equal(failure) }
      expect(created.length).to eq(3)
      expect_released
    end

    context "when release fails" do
      let(:release_error) { IOError.new("release unavailable") }
      let(:setup) { ->(agent) { allow(agent).to receive(:unload_async).and_return(Phronomy::TaskResult.failed(release_error)) } }

      it "exposes the exact retryable owner even with skip" do
        log = double(error: nil)
        Phronomy.configure { |config| config.logger = log }
        expect { parent.dispatch_parallel(task, on_error: :skip) }.to raise_error(Phronomy::MultiAgent::Orchestrator::ChildCleanupError) do |error|
          expect(error.code).to eq("multi_agent.child_cleanup_failed")
          expect(error.primary_error).to equal(failure)
          expect(error.failures).to eq([{agent: created.first, error: release_error}])
          expect(error.cause).to equal(failure)
        end
        child = created.first
        expect(worker.get(child.agent_id)).to equal(child)
        expect(log).to have_received(:error).with(a_string_including(child.agent_id, "release unavailable"))
        allow(child).to receive(:unload_async).and_call_original
        expect(child.unload!).to be(true)
        expect_released
        expect(requests.length).to eq(1)
      end

      it "reports all failed release owners in a parallel aggregate" do
        allow(Phronomy::RuntimeSettings.current.logger).to receive(:error) if Phronomy::RuntimeSettings.current.logger
        expect { parent.dispatch_parallel(task, task, on_error: :skip) }.to raise_error(Phronomy::MultiAgent::Orchestrator::ChildCleanupError) do |error|
          expect(error.failures.map { |item| item.fetch(:agent) }).to match_array(created)
        end
        created.each do |child|
          allow(child).to receive(:unload_async).and_call_original
          child.unload!
        end
      end
    end
  end

  it "rejects structural input errors before creating any child" do
    expect { parent.dispatch_parallel(task, task(config: nil), on_error: :skip) }.to raise_error(ArgumentError, /config must be a Hash/)
    expect(created).to be_empty
    expect(requests).to be_empty
  end

  it "preserves factories whose new method returns an Agent owner" do
    definition = worker
    factory = Object.new
    factory.define_singleton_method(:new) { definition.new }
    result = parent.subagent(factory, "question")
    expect(result.fetch(:agent_id)).to eq(created.first.agent_id)
    expect(created.first.unload!).to be(true)
  end

  it "preserves synchronous execution-option rejection before materialization" do
    expect { parent.dispatch_parallel_async(task, timeout: "invalid") }.to raise_error(TypeError, /timeout must be Numeric/)
    expect { parent.dispatch_parallel_async(task, cancellation_token: Object.new) }.to raise_error(TypeError, /cancellation_token/)
    expect { parent.dispatch_parallel_async(task, invocation_context: Object.new) }.to raise_error(TypeError, /invocation_context/)
    expect(created).to be_empty
    expect(requests).to be_empty
  end

  it "releases a child when inherited knowledge preparation fails" do
    parent.add_knowledge("knowledge")
    failure = IOError.new("knowledge write failed")
    allow(setup).to receive(:call) { |child| allow(child).to receive(:add_knowledge).and_raise(failure) }
    expect { parent.subagent(worker, "question") }.to raise_error { |error| expect(error).to equal(failure) }
    expect_released
    expect(requests).to be_empty
  end

  it "does not materialize queued children after a whole-execution timeout" do
    expire = controlled_execution_timeout
    gate = Queue.new
    entered = Queue.new
    allow(respond).to receive(:call) do |_request|
      entered << true
      gate.pop(timeout: 5)
      Phronomy::LLMAdapter::Response.new(content: "late answer")
    end
    pending = parent.dispatch_parallel_async(task, task, max_concurrency: 1, timeout: 60)
    expect(entered.pop(timeout: 3)).to be(true)
    expect(pending).not_to be_done
    expire.call
    expect { pending.wait_result(timeout: 3) }.to raise_error(Phronomy::ExecutionTimeoutError)
    expect(created.length).to eq(1)
    expect(worker.get(created.first.agent_id)).to equal(created.first)
    released = Queue.new
    allow(created.first).to receive(:unload_async).and_wrap_original do |original|
      original.call.tap { |result| result.on_complete { released << true } }
    end
    gate << true
    expect(released.pop(timeout: 3)).to be(true)
    expect_released
    expect(created.length).to eq(1)
  ensure
    gate << true
  end

  it "does not materialize children for already cancelled runs" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    pending = parent.dispatch_parallel_async(task, cancellation_token: token)
    expect { pending.wait_result(timeout: 3) }.to raise_error(Phronomy::ExecutionCancellationError)
    expect(created).to be_empty
  end

  it "releases earlier successful owners when a later child cannot be constructed" do
    failure = ArgumentError.new("cannot construct child")
    broken = Class.new(worker)
    allow(broken).to receive(:new).and_raise(failure)
    expect {
      parent.dispatch_parallel(task, task(agent: broken), max_concurrency: 1)
    }.to raise_error { |error| expect(error).to equal(failure) }
    expect(created.length).to eq(1)
    expect_released
    expect(requests.length).to eq(1)
  end

  it "keeps the primary failure and exact owner when successful-sibling release fails" do
    failure = RuntimeError.new("second child failed")
    cleanup = IOError.new("successful child release failed")
    calls = 0
    allow(respond).to receive(:call) do |_request|
      calls += 1
      raise failure if calls == 2
      Phronomy::LLMAdapter::Response.new(content: "answer")
    end
    allow(setup).to receive(:call) do |child|
      allow(child).to receive(:unload_async).and_return(Phronomy::TaskResult.failed(cleanup)) if created.length == 1
    end
    log = double(error: nil)
    Phronomy.configure { |config| config.logger = log }
    expect {
      parent.dispatch_parallel(task, task, max_concurrency: 1)
    }.to raise_error(Phronomy::MultiAgent::Orchestrator::ChildCleanupError) do |error|
      expect(error.primary_error).to equal(failure)
      expect(error.cause).to equal(failure)
      expect(error.failures).to eq([{agent: created.first, error: cleanup}])
    end
    expect(worker.get(created.first.agent_id)).to equal(created.first)
    expect_released([created.last])
    allow(created.first).to receive(:unload_async).and_call_original
    created.first.unload!
    expect(requests.length).to eq(2)
  end

  it "retains completed values as history while releasing their owners on timeout" do
    expire = controlled_execution_timeout
    entered, gate, released = Queue.new, Queue.new, Queue.new
    calls = 0
    allow(respond).to receive(:call) do |_request|
      calls += 1
      if calls == 2
        entered << true
        gate.pop(timeout: 5)
      end
      Phronomy::LLMAdapter::Response.new(content: "answer")
    end
    pending = parent.dispatch_parallel_async(task, task, max_concurrency: 1, timeout: 60)
    expect(entered.pop(timeout: 3)).to be(true)
    expect(pending).not_to be_done
    expire.call
    expect { pending.wait_result(timeout: 3) }.to raise_error(Phronomy::ExecutionTimeoutError) do |error|
      expect(error.outcomes.first.value.fetch(:agent_id)).to eq(created.first.agent_id)
      expect(error.outcomes.last.status).to eq(:unfinished)
    end
    expect_released([created.first])
    allow(created.last).to receive(:unload_async).and_wrap_original do |original|
      original.call.tap { |result| result.on_complete { released << true } }
    end
    gate << true
    expect(released.pop(timeout: 3)).to be(true)
    expect_released
  ensure
    gate << true
  end

  it "settles accepted failure cleanup while Runtime is draining" do
    entered, gate, waiting = Queue.new, Queue.new, Queue.new
    failure = RuntimeError.new("accepted failure")
    allow(respond).to receive(:call) do |_request|
      entered << true
      gate.pop(timeout: 5)
      raise failure
    end
    pending = parent.dispatch_parallel_async(task, on_error: :skip)
    expect(entered.pop(timeout: 3)).to be(true)
    runtime = Phronomy::Runtime.instance
    registry = Phronomy::Agent::ExecutionEnvironment.current.ownership
    allow(registry).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
      waiting << true
      original.call(deadline)
    end
    shutdown = Thread.new { runtime.shutdown(timeout: 3, cancel_grace: 1) }
    expect(waiting.pop(timeout: 3)).to be(true)
    expect(runtime.state).to eq(:draining)
    gate << true
    expect(pending.wait_result(timeout: 3)).to eq([nil])
    expect(shutdown.join(3)).not_to be_nil
    expect(shutdown.value.cleanup_complete?).to be(true)
    expect_released
    expect(requests.length).to eq(1)
  ensure
    gate << true
    shutdown&.join(4)
  end

  it "can release failed child preparation when shutdown begins before invocation" do
    entered, gate, waiting = Queue.new, Queue.new, Queue.new
    failure = IOError.new("accepted preparation failed")
    parent.add_knowledge("inherited")
    allow(setup).to receive(:call) do |child|
      allow(child).to receive(:add_knowledge) do |*|
        entered << true
        gate.pop(timeout: 5)
        raise failure
      end
    end
    pending = parent.dispatch_parallel_async(task, on_error: :skip)
    expect(entered.pop(timeout: 3)).to be(true)
    runtime = Phronomy::Runtime.instance
    registry = Phronomy::Agent::ExecutionEnvironment.current.ownership
    allow(registry).to receive(:wait_until_idle).and_wrap_original do |original, deadline|
      waiting << true
      original.call(deadline)
    end
    shutdown = Thread.new { runtime.shutdown(timeout: 3, cancel_grace: 1) }
    expect(waiting.pop(timeout: 3)).to be(true)
    gate << true
    expect(pending.wait_result(timeout: 3)).to eq([nil])
    expect(shutdown.join(3)).not_to be_nil
    expect(shutdown.value.cleanup_complete?).to be(true)
    expect_released
    expect(requests).to be_empty
  ensure
    gate << true
    shutdown&.join(4)
  end

  it "keeps cancelled physical work owned until its failed child can be released" do
    entered, gate, released = Queue.new, Queue.new, Queue.new
    allow(respond).to receive(:call) do |_request|
      entered << true
      gate.pop(timeout: 5)
      Phronomy::LLMAdapter::Response.new(content: "late answer")
    end
    token = Phronomy::Concurrency::CancellationToken.new
    pending = parent.dispatch_parallel_async(task, cancellation_token: token)
    expect(entered.pop(timeout: 3)).to be(true)
    child = created.first
    allow(child).to receive(:unload_async).and_wrap_original do |original|
      original.call.tap { |result| result.on_complete { released << true } }
    end
    token.cancel!
    expect { pending.wait_result(timeout: 3) }.to raise_error(Phronomy::ExecutionCancellationError)
    expect(child).not_to have_received(:unload_async)
    expect(worker.get(child.agent_id)).to equal(child)
    gate << true
    expect(released.pop(timeout: 3)).to be(true)
    expect_released
  ensure
    gate << true
  end

  it "reports incomplete shutdown while an unreturned child is waiting for approval" do
    approvals = Queue.new
    protected_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "direct_pending_approval"
      description "Wait for explicit approval"
      requires_approval true
      def execute = "approved"
    end
    worker.tools protected_tool => nil
    allow(respond).to receive(:call) do |_request|
      Phronomy::LLMAdapter::Response.new(tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "read", name: "direct_pending_approval", arguments: {})
      ], finish_reason: :tool_calls)
    end
    listener = ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required }
    allow(worker).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options, on_event: listener)
    end
    pending = parent.dispatch_parallel_async(task)
    expect(approvals.pop(timeout: 3)).not_to be_nil
    child = created.first
    runtime = Phronomy::Runtime.instance
    result = runtime.shutdown(timeout: 0.02, cancel_grace: 1)
    expect(result.cleanup_complete?).to be(false)
    expect(pending).not_to be_done
    expect(worker.get(child.agent_id)).to equal(child)
    expect { Phronomy.reset_runtime!(timeout: 0) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(Phronomy::Runtime.instance).to equal(runtime)
    expect(requests.length).to eq(1)
  end

  it "keeps approval pending and preserves the child after approved success" do
    approvals = Queue.new
    effects = []
    protected_tool = Class.new(Phronomy::Tool::Base) do
      tool_name "direct_approved_read"
      description "Read after explicit approval"
      requires_approval true
      define_method(:execute) {
        effects << :read
        "read"
      }
    end
    worker.tools protected_tool => nil
    calls = 0
    allow(respond).to receive(:call) do |_request|
      calls += 1
      if calls == 1
        Phronomy::LLMAdapter::Response.new(tool_calls: [
          Phronomy::Tool::CallRequest.new(id: "read", name: "direct_approved_read", arguments: {})
        ], finish_reason: :tool_calls)
      else
        Phronomy::LLMAdapter::Response.new(content: "answer")
      end
    end
    listener = ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required }
    allow(worker).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options, on_event: listener)
    end
    pending = parent.dispatch_parallel_async(task)
    approval = approvals.pop(timeout: 3)
    expect(approval).not_to be_nil
    child = created.first
    expect(pending).not_to be_done
    expect(effects).to be_empty
    expect { child.unload! }.to raise_error(Phronomy::AgentBusyError)
    child.approve_async(approval.execution_id, approval_request_id: approval.id).wait_result(timeout: 3)
    expect(pending.wait_result(timeout: 3).first.fetch(:agent_id)).to eq(child.agent_id)
    expect(effects).to eq([:read])
    expect(worker.get(child.agent_id)).to equal(child)
    expect(child.unload!).to be(true)
  end
end
