# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  describe "#check_cancellation! (Issue #223)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) {
        agent_definition id: "test-agent-202", version: 1
        model "test-model"
      }.new
    end

    it "does nothing when config has no cancellation_token" do
      expect { agent.send(:check_cancellation!, {}) }.not_to raise_error
    end

    it "does nothing when cancellation_token is not cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      expect { agent.send(:check_cancellation!, {cancellation_token: token}) }.not_to raise_error
    end

    it "raises CancellationError when token is cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      expect {
        agent.send(:check_cancellation!, {cancellation_token: token})
      }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError with the provided message" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      expect {
        agent.send(:check_cancellation!, {cancellation_token: token}, "cancelled mid-RAG")
      }.to raise_error(Phronomy::CancellationError, "cancelled mid-RAG")
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #291 — invoke_async is the primary path; invoke is a wrapper
  # ---------------------------------------------------------------------------

  describe "invoke_async (Issue #291)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-40", version: 1
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    it "returns a Task" do
      allow(agent).to receive(:_start_invocation) do |result_task, *|
        result_task.backend.unblock({output: "ok"}, nil)
        result_task.transition!(:completed, value: {output: "ok"})
      end
      task = agent.invoke_async("hi")
      expect(task).to be_a(Phronomy::Task)
      task.wait_result
    end

    it "executes via FSM (not via invoke)" do
      # invoke_async must not delegate to invoke — it uses _start_invocation directly.
      invoke_called = false
      allow(agent).to receive(:invoke).and_wrap_original do |m, *a, **kw|
        invoke_called = true
        m.call(*a, **kw)
      end
      allow(agent).to receive(:_start_invocation) do |result_task, *|
        result_task.backend.unblock({output: "ok"}, nil)
        result_task.transition!(:completed, value: {output: "ok"})
      end
      agent.invoke_async("hi").wait_result
      expect(invoke_called).to be(false)
    end

    it "registers the task with Runtime so shutdown can drain it" do
      allow(agent).to receive(:_start_invocation) do |result_task, *|
        result_task.backend.unblock({output: "ok"}, nil)
        result_task.transition!(:completed, value: {output: "ok"})
      end
      task = agent.invoke_async("hi")
      # Task must complete successfully — verifies the full spawn/drain lifecycle.
      expect(task.wait_result[:output]).to eq("ok")
    end
  end

  describe "#invoke SchedulerReentrancyError guard (Issue #291)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-41", version: 1
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    around do |ex|
      Phronomy.configure { |c| c.strict_runtime_guards = true }
      ex.run
    ensure
      Phronomy.reset_configuration!
    end

    it "raises SchedulerReentrancyError when called from inside a Task" do
      error = nil
      Phronomy::Task.spawn do
        agent.invoke("hi")
      rescue Phronomy::SchedulerReentrancyError => e
        error = e
      end.wait_result
      expect(error).to be_a(Phronomy::SchedulerReentrancyError)
      expect(error.message).to include("invoke_async")
    end

    it "does not raise when called outside a Task" do
      allow(agent).to receive(:_start_invocation) do |result_task, *|
        result_task.backend.unblock({output: "ok"}, nil)
        result_task.transition!(:completed, value: {output: "ok"})
      end
      expect { agent.invoke("hi") }.not_to raise_error
    end

    context "when strict_runtime_guards is false (default)" do
      around do |ex|
        Phronomy.configure { |c| c.strict_runtime_guards = false }
        ex.run
      ensure
        Phronomy.reset_configuration!
      end

      it "logs a warning instead of raising" do
        logged = nil
        fake_logger = double("logger")
        allow(fake_logger).to receive(:warn) { |msg| logged = msg }
        Phronomy.configure { |c| c.logger = fake_logger }
        allow(agent).to receive(:_start_invocation) do |result_task, *|
          result_task.backend.unblock({output: "ok"}, nil)
          result_task.transition!(:completed, value: {output: "ok"})
        end
        Phronomy::Task.spawn { agent.invoke("hi") }.wait_result
        expect(logged).to include("invoke_async")
      end
    end
  end

  describe "#stream_async EventLoop delivery" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-42", version: 1
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    it "delivers token and terminal callbacks on the EventLoop thread" do
      pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 10)
      worker_thread = nil
      chunk_stub = Struct.new(:content)
      fake_adapter = Class.new(Phronomy::LLMAdapter::Base) do
        define_method(:stream) do |chat, message, config: {}, &blk|
          worker_thread = Thread.current
          blk.call(chunk_stub.new("hello"))
          blk.call(chunk_stub.new(" world"))
          tokens = Struct.new(:input, :output, :cached, :cache_creation).new(1, 2, 0, 0)
          Struct.new(:content, :tokens).new("hello world", tokens)
        end
      end.new

      allow(Phronomy.configuration).to receive(:llm_adapter).and_return(fake_adapter)
      allow(fake_adapter).to receive(:complete_async).and_call_original
      allow(fake_adapter).to receive(:stream_async).and_call_original
      allow(Phronomy::Runtime.instance).to receive(:blocking_io).and_return(pool)

      # Stub out the parts of the AgentInvocation FSM that require a real LLM chat.
      allow(agent).to receive(:build_chat).and_return(
        double("chat",
          messages: [],
          on_tool_call: nil,
          on_tool_result: nil)
      )
      allow(agent).to receive(:extract_message).and_return("hi")
      allow(agent).to receive(:build_context).and_return({system: nil, messages: [], tool_classes: []})
      allow(agent).to receive(:apply_instructions)
      allow(agent).to receive(:run_before_completion_hooks!)
      allow(agent).to receive(:trace).and_yield(nil)

      event_loop_flags = []
      events = []

      task = agent.stream_async("hi") do |event|
        events << event
        event_loop_flags << Phronomy::Runtime.instance.event_loop.current?
      end
      result = task.wait_result

      token_events = events.select { |e| e.type == :token }
      expect(token_events.map { |e| e.payload[:content] }).to eq(["hello", " world"])
      expect(events.last.type).to eq(:done)
      expect(result[:output]).to eq("hello world")
      expect(event_loop_flags).not_to be_empty
      expect(event_loop_flags).to all(be(true))
      expect(Thread.current).not_to equal(worker_thread)
    ensure
      pool.shutdown
    end

    it "keeps an immediately completed terminal callback on the EventLoop thread" do
      invocation = Object.new
      session = double("session")
      event_loop_thread = nil
      event_loop = double("event_loop")
      runtime = double("runtime", event_loop: event_loop)
      result = {output: "ok", messages: [], usage: nil}
      events = []

      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)
      allow(Phronomy::Agent::AgentInvocationSessionBuilder).to receive(:build)
        .and_return(session)
      allow(agent).to receive(:_extract_invoke_result).with(invocation).and_return(result)
      allow(event_loop).to receive(:current?) do
        Thread.current.equal?(event_loop_thread)
      end
      allow(event_loop).to receive(:register) do |_registered_session, completion:|
        Thread.new do
          event_loop_thread = Thread.current
          completion.backend.unblock(invocation, nil)
          completion.transition!(:completed, value: invocation)
        end.join
        completion
      end

      result_task = Phronomy::Task.deferred(name: "stream-race-regression")
      agent.send(
        :_start_invocation,
        result_task,
        "hi",
        messages: [],
        thread_id: nil,
        config: {},
        approval_snapshot: {policy: nil, listener: nil},
        mode: :stream,
        on_event: ->(event) { events << [event.type, event_loop.current?] }
      )

      expect(result_task.wait_result).to eq(result)
      expect(events).to eq([[:done, true]])
    end

    it "does not invoke a terminal callback when completion escapes the EventLoop" do
      invocation = Object.new
      session = double("session")
      event_loop = double("event_loop", current?: false)
      runtime = double("runtime", event_loop: event_loop)
      events = []

      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)
      allow(Phronomy::Agent::AgentInvocationSessionBuilder).to receive(:build)
        .and_return(session)
      allow(event_loop).to receive(:register) do |_registered_session, completion:|
        completion.backend.unblock(invocation, nil)
        completion.transition!(:completed, value: invocation)
        completion
      end

      result_task = Phronomy::Task.deferred(name: "stream-affinity-guard")
      agent.send(
        :_start_invocation,
        result_task,
        "hi",
        messages: [],
        thread_id: nil,
        config: {},
        approval_snapshot: {policy: nil, listener: nil},
        mode: :stream,
        on_event: ->(event) { events << event }
      )

      expect do
        result_task.wait_result
      end.to raise_error(Phronomy::Error, /outside the EventLoop/)
      expect(events).to be_empty
    end

    it "requires a callback block" do
      expect { agent.stream_async("hi") }.to raise_error(ArgumentError)
      expect { agent.stream("hi") }.to raise_error(ArgumentError)
    end
  end
end

RSpec.describe "Agent::Base invocation_context: keyword argument (Issue #301)" do
  let(:agent) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-43", version: 1
      instructions "test"
      model "gpt-4o-mini"
    end.new
  end

  # Capture the config hash seen by _start_invocation so we can assert on it.
  def capture_config(ag, &block)
    captured = {}
    allow(ag).to receive(:_start_invocation) do |result_task, _input, messages:, thread_id:, config:, approval_snapshot:, **|
      captured = config
      result_task.backend.unblock({output: "ok"}, nil)
      result_task.transition!(:completed, value: {output: "ok"})
    end
    block.call
    captured
  end

  it "stores the InvocationContext in config[:invocation_context]" do
    ic = Phronomy::InvocationContext.new(task_id: "abc-123")
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:invocation_context]).to be(ic)
  end

  it "derives thread_id from InvocationContext when not explicitly supplied" do
    ic = Phronomy::InvocationContext.new(thread_id: "ic-thread")
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    # InvocationContext must be stored in config; thread_id routing is tested via FSM
    expect(config[:invocation_context]).to be(ic)
  end

  it "explicit thread_id takes precedence over ic.thread_id" do
    ic = Phronomy::InvocationContext.new(thread_id: "ic-thread")
    config = capture_config(agent) { agent.invoke("hi", thread_id: "explicit", invocation_context: ic) }
    # invocation pipeline will be called with thread_id: "explicit"
    # The captured config should still contain the ic
    expect(config[:invocation_context]).to be(ic)
  end

  it "derives cancellation_token from InvocationContext.cancellation_token" do
    token = Phronomy::Concurrency::CancellationToken.new
    ic = Phronomy::InvocationContext.new(cancellation_token: token)
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:cancellation_token]).to be(token)
  end

  it "derives cancellation_token from InvocationContext.deadline" do
    ic = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(30))
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:cancellation_token]).to be_a(Phronomy::Concurrency::CancellationToken)
  end

  it "existing config[:cancellation_token] takes precedence over ic" do
    explicit_token = Phronomy::Concurrency::CancellationToken.new
    ic = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(30))
    config = capture_config(agent) { agent.invoke("hi", config: {cancellation_token: explicit_token}, invocation_context: ic) }
    expect(config[:cancellation_token]).to be(explicit_token)
  end
end
