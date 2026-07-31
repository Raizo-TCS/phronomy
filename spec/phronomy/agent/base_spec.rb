# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  describe "#check_cancellation! (Issue #223)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) { model "test-model" }.new
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

  describe "#stream token callback via AsyncQueue (Issue #292)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    it "delivers :token StreamEvents to the caller block without running the block on a pool worker thread" do
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

      # Stub out the parts of _stream_impl that require a real LLM chat object
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

      caller_thread = Thread.current
      received_on_threads = []
      events = []

      agent.stream("hi") do |event|
        events << event
        received_on_threads << Thread.current if event.type == :token
      end

      token_events = events.select { |e| e.type == :token }
      expect(token_events.map { |e| e.payload[:content] }).to eq(["hello", " world"])
      # The token callbacks must have run on the caller's thread, not the pool worker
      expect(received_on_threads).not_to be_empty
      expect(received_on_threads).not_to include(worker_thread)
      expect(received_on_threads.uniq).to eq([caller_thread])
    ensure
      pool.shutdown
    end
  end
end

RSpec.describe "Agent::Base invocation_context: keyword argument (Issue #301)" do
  let(:agent) do
    Class.new(Phronomy::Agent::Base) do
      instructions "test"
      model "gpt-4o-mini"
    end.new
  end

  # Capture the config hash seen by _start_invocation so we can assert on it.
  def capture_config(ag, &block)
    captured = {}
    allow(ag).to receive(:_start_invocation) do |result_task, _input, messages:, thread_id:, config:, approval_snapshot:|
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
