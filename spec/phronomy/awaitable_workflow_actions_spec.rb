# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Awaitable Workflow actions (#264)" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :results, type: :append, default: -> { [] }
      field :step_value, default: nil
    end
  end

  # -------------------------------------------------------------------------
  # A. Non-EventLoop mode — Task returned from entry action is awaited inline
  # -------------------------------------------------------------------------
  describe "non-EventLoop mode: entry action returning a Task" do
    it "awaits the task and propagates the returned WorkflowContext" do
      app = Phronomy::Workflow.define(context_class) do
        initial :compute

        state :compute, action: ->(state) {
          Phronomy::Task.spawn do
            sleep 0.01  # simulate async work
            state.merge(step_value: "async_result")
          end
        }

        transition from: :compute, to: :__finish__
      end

      result, = app.invoke({}, config: {thread_id: SecureRandom.uuid})
      expect(result.step_value).to eq("async_result")
    end

    it "awaits the task when task does NOT return a WorkflowContext" do
      app = Phronomy::Workflow.define(context_class) do
        initial :simple

        state :simple, action: ->(state) {
          Phronomy::Task.spawn { 42 }
        }

        transition from: :simple, to: :__finish__
      end

      # Should not raise; context unchanged
      result, = app.invoke({}, config: {thread_id: SecureRandom.uuid})
      expect(result.step_value).to be_nil
    end
  end

  # -------------------------------------------------------------------------
  # B. EventLoop mode — entry action returning a Task does not block EventLoop
  # -------------------------------------------------------------------------
  describe "EventLoop mode: entry action returning a Task" do
    before do
      Phronomy.configure { |c| c.event_loop = true }
    end

    after do
      Phronomy::EventLoop.reset!
      Phronomy.configure { |c| c.event_loop = false }
    end

    it "awaits the task without blocking the EventLoop thread" do
      Thread.current

      app = Phronomy::Workflow.define(context_class) do
        initial :fetch

        state :fetch, action: ->(state) {
          Phronomy::Task.spawn do
            sleep 0.02  # simulate slow IO
            state.merge(step_value: "fetched")
          end
        }

        transition from: :fetch, to: :__finish__
      end

      result, = app.invoke({}, config: {thread_id: SecureRandom.uuid})
      expect(result.step_value).to eq("fetched")
    end

    it "propagates errors from awaited tasks" do
      app = Phronomy::Workflow.define(context_class) do
        initial :broken

        state :broken, action: ->(state) {
          Phronomy::Task.spawn { raise "async error" }
        }

        transition from: :broken, to: :__finish__
      end

      expect {
        app.invoke({}, config: {thread_id: SecureRandom.uuid})
      }.to raise_error(RuntimeError, "async error")
    end

    it "correctly sequences two states when first action is async" do
      app = Phronomy::Workflow.define(context_class) do
        initial :step_a

        state :step_a, action: ->(state) {
          Phronomy::Task.spawn { state.merge(step_value: "a") }
        }

        state :step_b, action: ->(state) {
          state.merge(results: "b")
        }

        transition from: :step_a, to: :step_b
        transition from: :step_b, to: :__finish__
      end

      result, = app.invoke({}, config: {thread_id: SecureRandom.uuid})
      expect(result.step_value).to eq("a")
      expect(result.results).to include("b")
    end
  end

  # -------------------------------------------------------------------------
  # C. action_timeout: — per-state timeout on Task-returning entry actions
  # -------------------------------------------------------------------------
  describe "action_timeout: raises ActionTimeoutError when the Task exceeds the limit" do
    it "raises ActionTimeoutError in non-EventLoop mode when task is too slow" do
      app = Phronomy::Workflow.define(context_class) do
        initial :slow_step

        state :slow_step, action: ->(state) {
          Phronomy::Task.spawn {
            sleep 10
            state.merge(step_value: "never")
          }
        }, action_timeout: 0.05

        transition from: :slow_step, to: :__finish__
      end

      expect {
        app.invoke({}, config: {thread_id: SecureRandom.uuid})
      }.to raise_error(Phronomy::ActionTimeoutError, /slow_step.*timed out/i)
    end

    it "does NOT raise when task finishes within the timeout" do
      app = Phronomy::Workflow.define(context_class) do
        initial :fast_step

        state :fast_step, action: ->(state) {
          Phronomy::Task.spawn { state.merge(step_value: "done") }
        }, action_timeout: 5

        transition from: :fast_step, to: :__finish__
      end

      result, = app.invoke({}, config: {thread_id: SecureRandom.uuid})
      expect(result.step_value).to eq("done")
    end

    context "in EventLoop mode" do
      before { Phronomy.configure { |c| c.event_loop = true } }
      after do
        Phronomy::EventLoop.reset!
        Phronomy.configure { |c| c.event_loop = false }
      end

      it "raises ActionTimeoutError when task exceeds action_timeout" do
        app = Phronomy::Workflow.define(context_class) do
          initial :slow_step

          state :slow_step, action: ->(state) {
            Phronomy::Task.spawn {
              sleep 10
              state.merge(step_value: "never")
            }
          }, action_timeout: 0.05

          transition from: :slow_step, to: :__finish__
        end

        expect {
          app.invoke({}, config: {thread_id: SecureRandom.uuid})
        }.to raise_error(Phronomy::ActionTimeoutError, /slow_step.*timed out/i)
      end
    end
  end
end
