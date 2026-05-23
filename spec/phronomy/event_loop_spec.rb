# frozen_string_literal: true

require "spec_helper"

# Tests for Phronomy::EventLoop:
#   - Singleton lifecycle
#   - Deadlock protection
#   - Full workflow execution in EventLoop mode (through Workflow public API)
#   - Wait-state halt / resume in EventLoop mode
#   - Error propagation
RSpec.describe Phronomy::EventLoop do
  after do
    described_class.reset!
    Phronomy.reset_configuration!
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
  # Singleton lifecycle
  # ---------------------------------------------------------------------------

  describe ".instance" do
    it "returns the same object on repeated calls" do
      expect(described_class.instance).to be(described_class.instance)
    end

    it "starts the background thread" do
      thread = described_class.instance.instance_variable_get(:@thread)
      expect(thread).to be_alive
    end
  end

  describe ".reset!" do
    it "creates a fresh instance after reset" do
      first = described_class.instance
      described_class.reset!
      expect(described_class.instance).not_to be(first)
    end

    it "stops the old background thread" do
      el = described_class.instance
      thread = el.instance_variable_get(:@thread)
      described_class.reset!
      # Give the kill a moment to propagate
      sleep 0.05
      expect(thread).not_to be_alive
    end
  end

  # ---------------------------------------------------------------------------
  # Deadlock protection
  # ---------------------------------------------------------------------------

  describe "deadlock protection" do
    it "raises Phronomy::Error when register is called from the EventLoop thread" do
      el = described_class.instance
      error = nil

      # Simulate calling register from within the EventLoop thread
      t = Thread.new do
        Thread.current[:phronomy_event_loop_thread] = true
        begin
          el.register(double("session", id: "fake"))
        rescue Phronomy::Error => e
          error = e
        end
      end
      t.join(2)
      expect(error).to be_a(Phronomy::Error)
      expect(error.message).to include("EventLoop")
    end
  end

  # ---------------------------------------------------------------------------
  # Workflow execution in EventLoop mode
  # ---------------------------------------------------------------------------

  describe "linear workflow (no wait states)" do
    it "drives the workflow to completion and returns the final context" do
      Phronomy.configure { |c| c.event_loop = true }
      app = build_linear_app(ctx_class)
      result = app.invoke({value: 0})

      expect(result.value).to eq(1)
      expect(result.phase).to eq(:__end__)
    end

    it "is isolated per thread_id (multiple sequential invocations)" do
      Phronomy.configure { |c| c.event_loop = true }
      app = build_linear_app(ctx_class)

      r1 = app.invoke({value: 10})
      r2 = app.invoke({value: 20})

      expect(r1.value).to eq(11)
      expect(r2.value).to eq(21)
    end
  end

  describe "workflow with wait state (halt and resume)" do
    it "halts at the wait state and returns a halted context" do
      Phronomy.configure { |c| c.event_loop = true }
      app = build_approval_app(str_ctx_class)
      halted = app.invoke({value: "start"})

      expect(halted.phase).to eq(:awaiting)
      expect(halted.value).to eq("start:prepared")
    end

    it "resumes after send_event and reaches :__end__" do
      Phronomy.configure { |c| c.event_loop = true }
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
      Phronomy.configure { |c| c.event_loop = true }
      expect { boom_app.invoke({value: 0}) }.to raise_error(RuntimeError, "deliberate error")
    end

    it "leaves the EventLoop running after a single workflow error" do
      Phronomy.configure { |c| c.event_loop = true }
      begin
        boom_app.invoke({value: 0})
      rescue RuntimeError
        nil # expected
      end

      # Subsequent invocations on a different (linear) app must still succeed
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
      Phronomy.configure { |c| c.event_loop = true }
      loop_instance = Phronomy::EventLoop.instance
      unknown_event = Phronomy::Event.new(type: :custom, target_id: "nonexistent-id", payload: {})
      warning_output = nil
      allow(loop_instance).to receive(:warn) { |msg| warning_output = msg }
      loop_instance.post(unknown_event)
      # Give the event-loop thread a moment to process the event.
      sleep 0.05
      expect(warning_output).not_to be_nil
      expect(warning_output).to include("nonexistent-id")
      expect(warning_output).to include("custom")
    end
  end

  # ---------------------------------------------------------------------------
  # Cooperative shutdown (issue #135)
  # ---------------------------------------------------------------------------

  describe "cooperative stop (issue #135)" do
    it "stops without force-killing the thread when no events are in-flight" do
      Phronomy.configure { |c| c.event_loop = true }
      loop_instance = Phronomy::EventLoop.instance
      # Ensure the loop is running.
      expect(loop_instance.instance_variable_get(:@thread)).not_to be_nil

      loop_instance.stop(timeout: 2)

      expect(loop_instance.instance_variable_get(:@thread)).to be_nil
    end

    it "accepts the timeout keyword argument" do
      Phronomy.configure { |c| c.event_loop = true }
      loop_instance = Phronomy::EventLoop.instance
      expect { loop_instance.stop(timeout: 1) }.not_to raise_error
    end
  end

  describe "force_kill: option (Issue #235)" do
    it "returns :clean when the loop stops cooperatively regardless of force_kill:" do
      Phronomy.configure { |c| c.event_loop = true }
      loop_instance = Phronomy::EventLoop.instance
      expect(loop_instance.stop(timeout: 2, force_kill: false)).to eq(:clean)
    end

    it "returns :clean with force_kill: true when the loop stops cooperatively" do
      Phronomy.configure { |c| c.event_loop = true }
      loop_instance = Phronomy::EventLoop.instance
      expect(loop_instance.stop(timeout: 2, force_kill: true)).to eq(:clean)
    end
  end
end
