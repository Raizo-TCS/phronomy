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
      config: {workflow_instance_id: "live-workflow"}
    )
    Timeout.timeout(1) { entered.pop }

    expect(
      workflow.signal(
        workflow_instance_id: "live-workflow",
        event: :complete,
        payload: {value: 42}
      )
    ).to be(true)

    expect(task.wait_result.value).to eq(42)
  end

  it "passes payloads to two-argument guards and ignores rejected events" do
    probe_ack = Queue.new
    correlated_context = Class.new do
      include Phronomy::WorkflowContext

      field :request_id

      # :probe is a FIFO barrier: consumed here so guard-mismatch dispatch
      # is guaranteed complete before the test checks task state.
      define_method(:handle_fsm_event) do |event|
        if event.type == :probe
          probe_ack << true
          return :consume
        end
        false
      end
    end

    entered = Queue.new
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
          event.payload[:request_id] == context.request_id
        }
      )
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {request_id: "current"},
      config: {workflow_instance_id: "guarded-workflow"}
    )
    Timeout.timeout(1) { entered.pop }

    workflow.signal(
      workflow_instance_id: "guarded-workflow",
      event: :complete,
      payload: {request_id: "stale"}
    )
    # :probe is FIFO after the stale event; when probe is consumed by the
    # context the guard-mismatch dispatch is guaranteed complete.
    # post_to_workflow bypasses signal's event-name guard intentionally while
    # still resolving workflow_instance_id to the currently bound fsm_session_id atomically.
    Phronomy::Runtime.instance.event_loop.post_to_workflow(
      workflow_instance_id: "guarded-workflow",
      event: :probe,
      payload: nil
    )
    Timeout.timeout(1) { probe_ack.pop }
    expect(task).not_to be_done

    workflow.signal(
      workflow_instance_id: "guarded-workflow",
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
      config: {workflow_instance_id: "finished-workflow"}
    )
    Timeout.timeout(1) { entered.pop }
    expect(
      workflow.signal(
        workflow_instance_id: "finished-workflow",
        event: :complete,
        payload: {value: 1}
      )
    ).to be(true)
    task.wait_result

    expect(
      workflow.signal(
        workflow_instance_id: "finished-workflow",
        event: :complete,
        payload: {value: 2}
      )
    ).to be(false)
  end

  it "rejects a nil workflow_instance_id" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting
      transition from: :waiting, on: :complete, to: :__finish__
    end

    expect {
      workflow.signal(
        workflow_instance_id: nil,
        event: :complete,
        payload: nil
      )
    }.to raise_error(ArgumentError, /workflow_instance_id/)
  end

  it "rejects undeclared event names before EventLoop admission" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting
      transition from: :waiting, on: :complete, to: :__finish__
    end

    expect {
      workflow.signal(
        workflow_instance_id: "x",
        event: :unknown,
        payload: nil
      )
    }.to raise_error(ArgumentError, /Unknown event/)
  end
end
