# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "event-driven Workflow actions" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :request_id
      field :answer
      field :events, type: :append, default: -> { [] }

      def handle_fsm_event(event)
        case event.type
        when :generation_completed
          return :consume unless event.payload[:request_id] == request_id

          self.answer = event.payload[:answer]
          self.events = events + [:generation_completed]
        when :generation_failed
          self.events = events + [:generation_failed]
        end
        false
      end
    end
  end

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  it "starts async work in entry and advances only from a later event" do
    entered = Queue.new
    workflow = nil

    workflow = Phronomy::Workflow.define(context_class) do
      initial :generating

      state :generating, action: ->(context) {
        entered << true
        task = Phronomy::Runtime.instance.spawn { "generated answer" }
        request_id = context.request_id

        task.on_complete do |value, error|
          workflow.signal(
            thread_id: context.thread_id,
            event: error ? :generation_failed : :generation_completed,
            payload: {
              request_id: request_id,
              answer: value,
              error: error
            }
          )
        end

        context
      }

      state :completed

      transition(
        from: :generating,
        on: :generation_completed,
        to: :completed
      )
      transition(
        from: :generating,
        on: :generation_failed,
        to: :completed
      )
      transition from: :completed, to: :__finish__
    end

    task = workflow.invoke_async(
      {request_id: "request-1"},
      config: {thread_id: "workflow-1"}
    )
    Timeout.timeout(1) { entered.pop }

    result = task.wait_result
    expect(result.answer).to eq("generated answer")
    expect(result.events).to eq([:generation_completed])
  end

  it "rejects Task-returning entry actions instead of awaiting them" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :invalid

      state :invalid, action: ->(_context) {
        Phronomy::Runtime.instance.spawn { "not implicitly awaited" }
      }

      transition from: :invalid, to: :__finish__
    end

    expect {
      workflow.invoke({})
    }.to raise_error(Phronomy::InvalidAsyncEntryActionError)
  end

  it "lets application context consume a stale correlated event" do
    entered = Queue.new
    stale_ack = Queue.new

    # Context class that signals when a stale event is consumed, enabling
    # deterministic verification without relying on timing.
    stale_context = Class.new do
      include Phronomy::WorkflowContext

      field :request_id
      field :answer
      field :events, type: :append, default: -> { [] }

      define_method(:handle_fsm_event) do |event|
        case event.type
        when :generation_completed
          unless event.payload[:request_id] == request_id
            stale_ack << true
            return :consume
          end

          self.answer = event.payload[:answer]
          self.events = events + [:generation_completed]
        end
        false
      end
    end

    workflow = Phronomy::Workflow.define(stale_context) do
      initial :generating
      state :generating, action: ->(context) {
        entered << true
        context
      }
      state :completed

      transition(
        from: :generating,
        on: :generation_completed,
        to: :completed
      )
      transition from: :completed, to: :__finish__
    end

    task = workflow.invoke_async(
      {request_id: "current"},
      config: {thread_id: "workflow-stale"}
    )
    Timeout.timeout(1) { entered.pop }

    expect(
      workflow.signal(
        thread_id: "workflow-stale",
        event: :generation_completed,
        payload: {request_id: "old", answer: "stale"}
      )
    ).to be(true)

    Timeout.timeout(1) { stale_ack.pop }
    expect(task).not_to be_done

    workflow.signal(
      thread_id: "workflow-stale",
      event: :generation_completed,
      payload: {request_id: "current", answer: "fresh"}
    )

    expect(task.wait_result.answer).to eq("fresh")
  end
end
