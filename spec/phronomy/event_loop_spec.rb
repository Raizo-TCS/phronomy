# frozen_string_literal: true

require "spec_helper"

# Tests for Phronomy::EventLoop, accessed through Runtime ownership.
#
# EventLoop is no longer a standalone singleton. It is owned by Runtime and
# accessed via Runtime#event_loop. The former EventLoop.instance,
# EventLoop.reset!, EventLoop#start, and EventLoop#stop APIs have been removed.
#
# Coverage:
#   - Runtime-owned EventLoop lifetime
#   - Deadlock / reentrancy protection
#   - Full workflow execution in EventLoop mode
#   - Wait-state halt / resume
#   - Error propagation
#   - Cooperative shutdown via Runtime#shutdown
RSpec.describe Phronomy::EventLoop do
  # Each example owns its own Runtime so teardown is local and isolated.
  let(:runtime) { Phronomy::Runtime.new }

  after do
    runtime.shutdown(timeout: 2)
  rescue
    nil
  end

  # ---------------------------------------------------------------------------
  # Helpers: minimal workflow context classes and graph definitions
  # ---------------------------------------------------------------------------

  def build_linear_app(ctx_class)
    Phronomy::Workflow.define(ctx_class) do
      initial :step
      state :step
      entry :step, ->(s) { s.value = s.value + 1 }
      transition from: :step, to: :__finish__
    end
  end

  def build_approval_app(ctx_class)
    Phronomy::Workflow.define(ctx_class) do
      initial :prepare
      state :prepare
      wait_state :awaiting
      state :confirm
      entry :prepare, ->(s) { s.value = "#{s.value}:prepared" }
      entry :confirm, ->(s) { s.value = "#{s.value}:confirmed" }
      transition from: :prepare, to: :awaiting
      transition from: :awaiting, on: :approve, to: :confirm
      transition from: :confirm, to: :__finish__
    end
  end

  let(:ctx_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: 0
    end
  end

  let(:str_ctx_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: ""
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime ownership
  # ---------------------------------------------------------------------------

  describe "Runtime-owned EventLoop" do
    it "returns the same EventLoop on repeated calls to the same Runtime" do
      expect(runtime.event_loop).to be(runtime.event_loop)
    end

    it "starts the background dispatcher task on first access" do
      el = runtime.event_loop
      task = el.instance_variable_get(:@task)
      expect(task).to be_alive
    end

    it "dispatcher is terminated after Runtime#shutdown" do
      el = runtime.event_loop
      task = el.instance_variable_get(:@task)
      runtime.shutdown(timeout: 2)
      expect(task).not_to be_alive
    end

    it "does not create an EventLoop when shutting down an unused Runtime" do
      r = Phronomy::Runtime.new
      r.shutdown(timeout: 1)
      expect(r.instance_variable_get(:@event_loop)).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Deadlock protection
  # ---------------------------------------------------------------------------

  describe "deadlock protection" do
    it "raises when register is called from within the EventLoop dispatch thread" do
      el = runtime.event_loop
      task = el.instance_variable_get(:@task)
      error = nil

      # current? checks Task.current.equal?(@task), so we must set the actual task.
      t = Thread.new do
        Thread.current[:phronomy_current_task] = task
        begin
          el.register(double("session", id: "fake"))
        rescue Phronomy::Error => e
          error = e
        ensure
          Thread.current[:phronomy_current_task] = nil
        end
      end
      t.join(2)
      expect(error).to be_a(Phronomy::Error)
      expect(error.message).to include("EventLoop")
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow execution in EventLoop mode (via default Runtime)
  # ---------------------------------------------------------------------------

  describe "linear workflow (no wait states)" do
    it "drives the workflow to completion and returns the final context" do
      app = build_linear_app(ctx_class)
      result = app.invoke({value: 0})

      expect(result.value).to eq(1)
      expect(result.phase).to eq(:__end__)
    end

    it "is isolated per thread_id (multiple sequential invocations)" do
      app = build_linear_app(ctx_class)

      r1 = app.invoke({value: 10})
      r2 = app.invoke({value: 20})

      expect(r1.value).to eq(11)
      expect(r2.value).to eq(21)
    end
  end

  describe "workflow with wait state (halt and resume)" do
    it "halts at the wait state and returns a halted context" do
      app = build_approval_app(str_ctx_class)
      halted = app.invoke({value: "start"})

      expect(halted.phase).to eq(:awaiting)
      expect(halted.value).to eq("start:prepared")
    end

    it "resumes after send_event and reaches :__end__" do
      app = build_approval_app(str_ctx_class)
      halted = app.invoke({value: "start"})
      final = app.send_event(state: halted, event: :approve)

      expect(final.phase).to eq(:__end__)
      expect(final.value).to eq("start:prepared:confirmed")
    end
  end

  # ---------------------------------------------------------------------------
  # Error propagation
  # ---------------------------------------------------------------------------

  describe "error propagation" do
    let(:boom_app) do
      Phronomy::Workflow.define(ctx_class) do
        initial :boom
        state :boom
        entry :boom, ->(_s) { raise "deliberate error" }
        transition from: :boom, to: :__finish__
      end
    end

    it "re-raises the exception in the calling thread" do
      expect { boom_app.invoke({value: 0}) }.to raise_error(RuntimeError, "deliberate error")
    end

    it "leaves the EventLoop running after a single workflow error" do
      begin
        boom_app.invoke({value: 0})
      rescue RuntimeError
        nil
      end

      app = build_linear_app(ctx_class)
      result = app.invoke({value: 5})
      expect(result.value).to eq(6)
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown target_id warning
  # ---------------------------------------------------------------------------

  describe "unknown target_id warning" do
    it "emits a warn message when an event has no registered handler" do
      el = runtime.event_loop
      unknown_event = Phronomy::Event.new(type: :custom, target_id: "nonexistent-id", payload: {})
      warning_output = nil
      allow(el).to receive(:warn) { |msg| warning_output = msg }
      el.post(unknown_event)
      sleep 0.05
      expect(warning_output).not_to be_nil
      expect(warning_output).to include("nonexistent-id")
      expect(warning_output).to include("custom")
    end
  end

  # ---------------------------------------------------------------------------
  # Cooperative shutdown via Runtime (replaces EventLoop#stop tests)
  # ---------------------------------------------------------------------------

  describe "cooperative shutdown via Runtime#shutdown" do
    it "terminates the dispatcher cleanly when no events are in-flight" do
      el = runtime.event_loop
      expect(el.instance_variable_get(:@task)).not_to be_nil

      result = runtime.shutdown(timeout: 2)

      expect(result.cleanup_complete?).to be(true)
      expect(el.task_alive?).to be(false)
    end

    it "accepts the timeout keyword argument" do
      runtime.event_loop
      expect { runtime.shutdown(timeout: 1) }.not_to raise_error
    end

    it "returns a clean ShutdownResult when the loop stops cooperatively" do
      runtime.event_loop
      result = runtime.shutdown(timeout: 2)
      expect(result.clean?).to be(true)
    end

    it "completes abandoned Task waiters on the EventLoop thread" do
      el = runtime.event_loop
      started = Thread::Queue.new
      release = Thread::Queue.new
      session = double("session", id: "forced-shutdown-affinity")
      completion = Phronomy::Task.deferred(name: "forced-shutdown-waiter")
      callback_on_event_loop = nil
      callback_error = nil

      allow(session).to receive(:start) do
        started.push(:started)
        release.pop
      end
      allow(session).to receive(:handle)

      completion.on_complete do |_value, error|
        callback_on_event_loop = el.current?
        callback_error = error
      end

      el.register(session, completion: completion)
      started.pop

      result = runtime.shutdown(timeout: 0.05, cancel_grace: 1)

      expect(result.event_loop_status).to eq(:cancelled)
      expect(callback_on_event_loop).to be(true)
      expect(callback_error).to be_a(Phronomy::CancellationError)
    ensure
      release&.push(:release)
    end
  end
end
