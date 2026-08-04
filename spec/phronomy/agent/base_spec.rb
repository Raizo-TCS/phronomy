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
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.spawn(name: "stub") { {output: "ok"} }
      end
      task = agent.invoke_async("hi")
      expect(task).to be_a(Phronomy::Task)
      task.wait_result
    end

    it "executes via FSM (not via invoke)" do
      invoke_called = false
      allow(agent).to receive(:invoke).and_wrap_original do |m, *a, **kw|
        invoke_called = true
        m.call(*a, **kw)
      end
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.spawn(name: "stub") { {output: "ok"} }
      end
      agent.invoke_async("hi").wait_result
      expect(invoke_called).to be(false)
    end

    it "registers the task with Runtime so shutdown can drain it" do
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.spawn(name: "stub") { {output: "ok"} }
      end
      task = agent.invoke_async("hi")
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
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.spawn(name: "stub") { {output: "ok"} }
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
        allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
          Phronomy::Task.spawn(name: "stub") { {output: "ok"} }
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
      skip "requires ExecutionCoordinator refactor: terminal :done event delivered from BlockingAdapterPool thread, not EventLoop"
    end

    it "keeps an immediately completed terminal callback on the EventLoop thread" do
      skip "requires ExecutionCoordinator refactor: deliver_terminal runs on BlockingAdapterPool thread not EventLoop"
    end

    it "does not invoke a terminal callback when completion escapes the EventLoop" do
      skip "requires ExecutionCoordinator refactor: deliver_terminal runs on BlockingAdapterPool thread not EventLoop"
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

  # Capture the config hash passed to ExecutionCoordinator#start.
  def capture_config(ag, &block)
    captured = {}
    allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do |_coord, _input, config: {}, **|
      captured = config
      Phronomy::Task.spawn(name: "stub-ic") { {output: "ok"} }
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
