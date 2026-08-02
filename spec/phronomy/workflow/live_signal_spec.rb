# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Phronomy::Workflow, "#signal" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value

      def handle_fsm_event(event)
        self.value = event.payload[:value] if event.type == :complete
        false
      end
    end
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "admits a declared event for a live session" do
    entered = Queue.new
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting, action: ->(context) {
        entered << true
        context
      }
      state :done

      transition from: :waiting, on: :complete, to: :done
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {},
      config: {thread_id: "live-workflow"}
    )
    Timeout.timeout(1) { entered.pop }

    expect(
      workflow.signal(
        thread_id: "live-workflow",
        event: :complete,
        payload: {value: 42}
      )
    ).to be(true)

    expect(task.wait_result.value).to eq(42)
  end

  it "passes payloads to two-argument guards and ignores rejected events" do
    correlated_context = Class.new do
      include Phronomy::WorkflowContext

      field :request_id
    end

    entered = Queue.new
    guard_rejected = Queue.new
    workflow = Phronomy::Workflow.define(correlated_context) do
      initial :waiting
      state :waiting, action: ->(context) {
        entered << true
        context
      }
      state :done

      transition(
        from: :waiting,
        on: :complete,
        to: :done,
        guard: ->(context, event) {
          result = event.payload[:request_id] == context.request_id
          guard_rejected << true unless result
          result
        }
      )
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {request_id: "current"},
      config: {thread_id: "guarded-workflow"}
    )
    Timeout.timeout(1) { entered.pop }

    workflow.signal(
      thread_id: "guarded-workflow",
      event: :complete,
      payload: {request_id: "stale"}
    )
    Timeout.timeout(1) { guard_rejected.pop }
    expect(task).not_to be_done

    workflow.signal(
      thread_id: "guarded-workflow",
      event: :complete,
      payload: {request_id: "current"}
    )
    expect(task.wait_result.request_id).to eq("current")
  end

  it "returns false after the session has terminated" do
    entered = Queue.new
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting, action: ->(context) {
        entered << true
        context
      }
      transition from: :waiting, on: :complete, to: :__finish__
    end

    task = workflow.invoke_async(
      {},
      config: {thread_id: "finished-workflow"}
    )
    Timeout.timeout(1) { entered.pop }
    expect(
      workflow.signal(
        thread_id: "finished-workflow",
        event: :complete,
        payload: {value: 1}
      )
    ).to be(true)
    task.wait_result

    expect(
      workflow.signal(
        thread_id: "finished-workflow",
        event: :complete,
        payload: {value: 2}
      )
    ).to be(false)
  end

  it "rejects a nil thread_id" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting
      transition from: :waiting, on: :complete, to: :__finish__
    end

    expect {
      workflow.signal(
        thread_id: nil,
        event: :complete,
        payload: nil
      )
    }.to raise_error(ArgumentError, /thread_id/)
  end

  it "rejects undeclared event names before EventLoop admission" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting
      transition from: :waiting, on: :complete, to: :__finish__
    end

    expect {
      workflow.signal(
        thread_id: "x",
        event: :unknown,
        payload: nil
      )
    }.to raise_error(ArgumentError, /Unknown event/)
  end
end
