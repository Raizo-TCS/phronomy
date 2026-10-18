# frozen_string_literal: true

require "spec_helper"
require_relative "../multi_agent/support/durable_coordination"

RSpec.describe "Agent logical iteration budget" do
  include_context "durable coordination runtime"

  def lookup_tool(approval: false, &effect)
    Class.new(Phronomy::Tool::Base) do
      tool_name "budget_lookup"
      description "Count one lookup"
      requires_approval approval
      define_method(:execute) {
        effect&.call
        "found"
      }
    end
  end

  def install_adapter(&reply)
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:initialize) { |operation| @operation = operation }
      protected

      define_method(:perform_complete) { |request, cancellation_token:| @operation.call(request) }
      define_method(:perform_stream) do |request, cancellation_token:, &emit|
        response = @operation.call(request)
        emit.call(Phronomy::LLMAdapter::StreamChunk.new(content: response.content)) if response.content
        response
      end
    end.new(reply)
    Phronomy.configure { |c| c.llm_adapter = adapter }
  end

  def tool_reply(id, count: 1)
    Phronomy::LLMAdapter::Response.new(tool_calls: Array.new(count) { |i|
      Phronomy::Tool::CallRequest.new(id: "#{id}-#{i}", name: "budget_lookup", arguments: {})
    })
  end

  [:invoke_async, :stream_async].each do |mode|
    it "allows nine Tool rounds followed by a final tenth LLM call in #{mode}" do
      turns = effects = 0
      worker.tools lookup_tool { effects += 1 } => nil
      expect(RubyLLM).not_to receive(:chat)
      install_adapter do |_request|
        turns += 1
        (turns < 10) ? tool_reply(turns) : Phronomy::LLMAdapter::Response.new(content: "done")
      end
      agent = worker.create(persistence: store.agent, on_event: ->(_e) {})
      result = agent.public_send(mode, "review").wait_result(timeout: 5)
      expect(result[:output]).to eq("done")
      expect(turns).to eq(10)
      expect(effects).to eq(9)
      expect(store.agent.runs(agent.agent_id).first.llm_calls.length).to eq(10)
    end
  end

  it "blocks call N+1, persists the last Tool result and releases admission after failure" do
    worker.max_iterations 3
    turns = effects = 0
    hooks = []
    worker.before_llm_input { |input|
      hooks << input.call_sequence
      nil
    }
    worker.tools lookup_tool { effects += 1 } => nil
    install_adapter { |_request|
      turns += 1
      tool_reply(turns)
    }
    agent = worker.create(persistence: store.agent)
    expect { agent.invoke("loop") }.to raise_error(Phronomy::RecursionLimitError, /max_iterations \(3\).*3 LLM calls/)
    expect([turns, effects]).to eq([3, 3])
    expect(hooks).to eq([1, 2, 3])
    run = store.agent.runs(agent.agent_id).first
    expect(run.status).to eq(:failed)
    expect(run.llm_calls.map(&:sequence)).to eq([1, 2, 3])
    expect(store.agent.journals.read(agent.agent_id).count { |r| r.kind == :tool_message }).to eq(3)
    install_adapter { |_request| Phronomy::LLMAdapter::Response.new(content: "next") }
    expect(agent.invoke("new execution")[:output]).to eq("next")
  end

  it "does not charge multiple Tools as multiple LLM iterations" do
    worker.max_iterations 2
    turns = 0
    effects = Queue.new
    worker.tools lookup_tool { effects << true } => nil
    install_adapter do |_request|
      turns += 1
      (turns == 1) ? tool_reply(turns, count: 40) : Phronomy::LLMAdapter::Response.new(content: "done")
    end
    agent = worker.create(persistence: store.agent)
    expect(agent.invoke("many tools")[:output]).to eq("done")
    expect(turns).to eq(2)
    expect(effects.size).to eq(40)
  end

  it "allows a final response at limit one and starts a fresh budget for a new execution" do
    worker.max_iterations 1
    llm = LLMStub.activate(responses: ["first", "second"])
    agent = worker.create(persistence: store.agent)
    expect(agent.invoke("one")[:output]).to eq("first")
    expect(agent.invoke("two")[:output]).to eq("second")
    expect(llm.calls.length).to eq(2)
    expect(store.agent.runs(agent.agent_id).map { |r| r.llm_calls.length }).to eq([1, 1])
  end

  it "allows zero as a configuration value and dispatches no LLM call" do
    worker.max_iterations 0
    llm = LLMStub.activate(responses: ["must not call"])
    agent = worker.create(persistence: store.agent)
    expect { agent.invoke("zero") }.to raise_error(Phronomy::RecursionLimitError, /max_iterations \(0\)/)
    expect(llm.calls).to be_empty
    expect(store.agent.runs(agent.agent_id).first.llm_calls).to be_empty
  end

  [-1, 1.5, "2"].each do |invalid|
    it "rejects invalid iteration limit #{invalid.inspect} before inference" do
      worker.max_iterations invalid
      llm = LLMStub.activate(responses: ["must not call"])
      agent = worker.create(persistence: store.agent)
      expect { agent.invoke("invalid") }.to raise_error(ArgumentError, /max_iterations/)
      expect(llm.calls).to be_empty
    end
  end

  [false, true].each do |restart|
    it "retains consumed calls and the admitted limit through approval, restart=#{restart}" do
      worker.max_iterations 1
      effects = 0
      worker.tools lookup_tool(approval: true) { effects += 1 } => nil
      approvals = Queue.new
      listener = ->(e) { approvals << e.payload.fetch(:request) if e.type == :approval_required }
      first = LLMStub.activate(responses: [LLMStub.tool_call_response("budget_lookup")])
      agent = worker.create(persistence: store.agent, on_event: listener)
      agent.invoke_async("approve")
      approval = Timeout.timeout(3) { approvals.pop }
      id = agent.agent_id
      expect(first.calls.length).to eq(1)
      expect(effects).to eq(0)
      # Changing the class after admission cannot grant the active run more calls.
      worker.max_iterations 99
      backend = store
      if restart
        backend = reboot(store.snapshot)
        agent = worker.load(id, persistence: backend.agent, on_event: listener)
        approval = Timeout.timeout(3) { approvals.pop }
      end
      next_llm = LLMStub.activate(responses: ["must not call"])
      expect { agent.approve(approval.execution_id, approval_request_id: approval.id, approved: true) }
        .to raise_error(Phronomy::RecursionLimitError, /max_iterations \(1\)/)
      expect(next_llm.calls).to be_empty
      expect(effects).to eq(1)
      expect(backend.agent.executions.load(approval.execution_id).llm_calls.length).to eq(1)
    end
  end

  it "allows the remaining call after a fresh Runtime and approval restoration" do
    worker.max_iterations 2
    effects = 0
    worker.tools lookup_tool(approval: true) { effects += 1 } => nil
    approvals = Queue.new
    listener = ->(e) { approvals << e.payload.fetch(:request) if e.type == :approval_required }
    first = LLMStub.activate(responses: [LLMStub.tool_call_response("budget_lookup")])
    agent = worker.create(persistence: store.agent, on_event: listener)
    agent.invoke_async("approve")
    Timeout.timeout(3) { approvals.pop }
    backend = reboot(store.snapshot)
    second = LLMStub.activate(responses: ["done"])
    loaded = worker.load(agent.agent_id, persistence: backend.agent, on_event: listener)
    approval = Timeout.timeout(3) { approvals.pop }
    expect(loaded.approve(approval.execution_id, approval_request_id: approval.id, approved: true)[:output]).to eq("done")
    expect([first.calls.length, second.calls.length, effects]).to eq([1, 1, 1])
    expect(backend.agent.executions.load(approval.execution_id).llm_calls.length).to eq(2)
  end

  it "does not reset the budget over repeated approval suspensions" do
    worker.max_iterations 2
    effects = 0
    worker.tools lookup_tool(approval: true) { effects += 1 } => nil
    approvals = Queue.new
    listener = ->(e) { approvals << e.payload.fetch(:request) if e.type == :approval_required }
    llm = LLMStub.activate(responses: [LLMStub.tool_call_response("budget_lookup")])
    agent = worker.create(persistence: store.agent, on_event: listener)
    agent.invoke_async("twice")
    first = Timeout.timeout(3) { approvals.pop }
    agent.approve_async(first.execution_id, approval_request_id: first.id, approved: true)
    second = Timeout.timeout(3) { approvals.pop }
    expect { agent.approve_async(second.execution_id, approval_request_id: second.id, approved: true).wait_result(timeout: 3) }
      .to raise_error(Phronomy::RecursionLimitError, /max_iterations \(2\)/)
    expect([llm.calls.length, effects]).to eq([2, 2])
    expect(store.agent.executions.load(second.execution_id).llm_calls.length).to eq(2)
  end

  it "counts a RubyLLM HTTP retry as part of one logical call" do
    worker.max_iterations 1
    saved_retries = RubyLLM.config.max_retries
    RubyLLM.config.max_retries = 1
    recorder = LLMStub.activate(responses: ["done"])
    attempts = 0
    WebMock.stub_request(:post, LLMStub::CHAT_ENDPOINT_PATTERN).to_return do |request|
      attempts += 1
      if attempts == 1
        {status: 503, headers: {"Content-Type" => "application/json"}, body: '{"error":"temporary"}'}
      else
        recorder.handle(request)
      end
    end
    agent = worker.create(persistence: store.agent)
    expect(agent.invoke("retry")[:output]).to eq("done")
    expect(attempts).to eq(2)
    expect(store.agent.runs(agent.agent_id).first.llm_calls.length).to eq(1)
  ensure
    RubyLLM.config.max_retries = saved_retries
  end

  it "counts recorded calls in legacy suspended executions without the new limit metadata" do
    worker.max_iterations 1
    worker.tools lookup_tool(approval: true) => nil
    approvals = Queue.new
    listener = ->(e) { approvals << e.payload.fetch(:request) if e.type == :approval_required }
    LLMStub.activate(responses: [LLMStub.tool_call_response("budget_lookup")])
    agent = worker.create(persistence: store.agent, on_event: listener)
    agent.invoke_async("legacy")
    approval = Timeout.timeout(3) { approvals.pop }
    store.agent.transaction do |tx|
      run = tx.executions.load(approval.execution_id)
      tx.executions.save(run.execution_id, expected_revision: run.execution_revision,
        execution: run.with(metadata: run.metadata.except("agent_max_iterations")))
    end
    backend = reboot(store.snapshot)
    llm = LLMStub.activate(responses: ["must not call"])
    loaded = worker.load(agent.agent_id, persistence: backend.agent, on_event: listener)
    approval = Timeout.timeout(3) { approvals.pop }
    expect { loaded.approve(approval.execution_id, approval_request_id: approval.id, approved: true) }
      .to raise_error(Phronomy::RecursionLimitError, /max_iterations \(1\)/)
    expect(llm.calls).to be_empty
  end

  it "counts a provider outcome resolved after restart without redispatching it" do
    worker.max_iterations 1
    effects = 0
    worker.tools lookup_tool { effects += 1 } => nil
    agent = worker.create(persistence: store.agent)
    checkpoint = nil
    store.after_commit = proc do |backend|
      run = backend.agent.runs(agent.agent_id).first
      checkpoint ||= backend.snapshot if run&.phase == :calling_llm
    end
    LLMStub.activate(responses: ["original"])
    agent.invoke("resolve")
    backend = reboot(checkpoint)
    events = Queue.new
    loaded = worker.load(agent.agent_id, persistence: backend.agent,
      on_event: ->(e) { events << e.payload if e.type == :recovery_resolution_required })
    recovery = Timeout.timeout(3) { events.pop }
    llm = LLMStub.activate(responses: ["must not call"])
    loaded.resolve_async(recovery.fetch(:execution_id),
      expected_execution_revision: recovery.fetch(:execution_revision),
      subject: recovery.fetch(:subject), outcome: :succeeded, result: tool_reply("resolved").to_h).wait_result(timeout: 5)
    recovery = Timeout.timeout(3) { events.pop }
    expect(recovery.fetch(:subject).fetch(:type)).to eq(:tool_invocation)
    expect {
      loaded.resolve_async(recovery.fetch(:execution_id),
        expected_execution_revision: recovery.fetch(:execution_revision),
        subject: recovery.fetch(:subject), outcome: :succeeded, result: "already performed").wait_result(timeout: 5)
    }.to raise_error(Phronomy::RecursionLimitError, /max_iterations \(1\)/)
    expect(llm.calls).to be_empty
    expect(effects).to eq(0)
    expect(backend.agent.executions.load(recovery.fetch(:execution_id)).llm_calls.length).to eq(1)
  end
end
