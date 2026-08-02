# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe "Workflow transition actions" do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :events, type: :replace, default: -> { [] }
      field :route
      field :selected
      field :one_arg_seen, default: false
      field :event_type
      field :event_payload
      field :event_target_matches, default: false
      field :answer
      field :count, default: 0
      field :approved, default: false
    end
  end

  def invoke_bounded(workflow, input, config: {})
    Timeout.timeout(3) do
      workflow.invoke(input, config: config)
    end
  end

  def wait_bounded(task)
    Timeout.timeout(3) { task.wait_result }
  end

  def completed_task(value)
    task = Phronomy::Task.deferred(name: "completed-transition-action")
    task.backend.unblock(value, nil)
    task.transition!(:completed, value: value)
    task
  end

  it "runs source exit, selected transition action, then target entry" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :source
      state :source
      state :target

      self.exit :source, ->(context) {
        context.events = context.events + [:exit]
        nil
      }
      entry :target, ->(context) {
        context.events = context.events + [:entry]
        context
      }

      transition(
        from: :source,
        to: :target,
        action: ->(context) {
          context.merge(events: context.events + [:action])
        }
      )
      transition from: :target, to: :__finish__
    end

    result = invoke_bounded(workflow, {})

    expect(result.events).to eq(%i[exit action entry])
  end

  it "supports one-argument and two-argument transition actions" do
    entered = Queue.new
    one_argument_action = Class.new do
      def call(context)
        context.merge(one_arg_seen: true)
      end
    end.new

    workflow = Phronomy::Workflow.define(context_class) do
      initial :source
      state :source
      state :waiting
      state :done

      entry :waiting, ->(context) {
        entered << true
        context
      }

      transition(
        from: :source,
        to: :waiting,
        action: one_argument_action
      )
      transition(
        from: :waiting,
        on: :advance,
        to: :done,
        action: ->(context, event) {
          context.merge(
            event_type: event.type,
            event_payload: event.payload
          )
        }
      )
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {},
      config: {thread_id: "transition-arity"}
    )
    Timeout.timeout(1) { entered.pop }

    expect(
      workflow.signal(
        thread_id: "transition-arity",
        event: :advance,
        payload: {value: 42}
      )
    ).to be(true)

    result = wait_bounded(task)
    expect(result.one_arg_seen).to be(true)
    expect(result.event_type).to eq(:advance)
    expect(result.event_payload).to eq(value: 42)
  end

  it "selects the action belonging to the first matching guard" do
    evaluated = []
    workflow = Phronomy::Workflow.define(context_class) do
      initial :routing
      state :routing
      state :done

      transition(
        from: :routing,
        to: :done,
        guard: ->(context) {
          evaluated << :first_guard
          context.route == :first
        },
        action: ->(context) {
          context.merge(selected: :first)
        }
      )
      transition(
        from: :routing,
        to: :done,
        guard: ->(_context) {
          evaluated << :second_guard
          true
        },
        action: ->(context) {
          context.merge(selected: :second)
        }
      )
      transition from: :done, to: :__finish__
    end

    first = invoke_bounded(workflow, {route: :first})
    expect(first.selected).to eq(:first)
    expect(evaluated).to eq([:first_guard])

    evaluated.clear
    second = invoke_bounded(workflow, {route: :second})
    expect(second.selected).to eq(:second)
    expect(evaluated).to eq(%i[first_guard second_guard])
  end

  it "passes the synthetic state_completed event to auto-transition actions" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :source
      state :source

      transition(
        from: :source,
        to: :__finish__,
        action: ->(context, event) {
          context.merge(
            event_type: event.type,
            event_payload: event.payload,
            event_target_matches: event.target_id == context.thread_id
          )
        }
      )
    end

    result = invoke_bounded(
      workflow,
      {},
      config: {thread_id: "auto-transition-event"}
    )

    expect(result.event_type).to eq(:state_completed)
    expect(result.event_payload).to be_nil
    expect(result.event_target_matches).to be(true)
  end

  it "applies transition and entry results using the FSM context protocol" do
    duck_context_class = Class.new do
      attr_reader :value
      attr_accessor :thread_id, :phase

      def initialize(value)
        @value = value
      end

      def set_graph_metadata(thread_id:, phase: nil)
        @thread_id = thread_id
        @phase = phase if phase
        self
      end
    end

    workflow = Phronomy::Workflow.define(context_class) do
      initial :source
      state :source
      state :target

      entry :target, ->(context) {
        duck_context_class.new("#{context.value}:entry")
      }

      transition(
        from: :source,
        to: :target,
        action: ->(_context) {
          duck_context_class.new("action")
        }
      )
      transition from: :target, to: :__finish__
    end

    result = invoke_bounded(workflow, {})

    expect(result).not_to be_a(Phronomy::WorkflowContext)
    expect(result.value).to eq("action:entry")
    expect(result.phase).to eq(:__end__)
  end

  it "runs transition actions when resuming a halted workflow" do
    workflow = Phronomy::Workflow.define(context_class) do
      initial :awaiting_approval
      wait_state :awaiting_approval
      state :done

      transition(
        from: :awaiting_approval,
        on: :approve,
        to: :done,
        action: ->(context, event) {
          context.merge(
            approved: true,
            event_type: event.type
          )
        }
      )
      transition from: :done, to: :__finish__
    end

    halted = invoke_bounded(
      workflow,
      {},
      config: {thread_id: "transition-resume"}
    )
    expect(halted.halted?).to be(true)

    result = Timeout.timeout(3) do
      workflow.send_event(
        state: halted,
        event: :approve
      )
    end

    expect(result.approved).to be(true)
    expect(result.event_type).to eq(:approve)
  end

  it "allows an action to start async work and signal a later event" do
    entered = Queue.new
    workflow = nil

    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting, action: ->(context) {
        entered << true
        context
      }
      state :processing
      state :done

      transition(
        from: :waiting,
        on: :start,
        to: :processing,
        action: ->(context) {
          thread_id = context.thread_id
          task = Phronomy::Runtime.instance.spawn { "async-result" }
          task.on_complete do |value, error|
            workflow.signal(
              thread_id: thread_id,
              event: :work_completed,
              payload: {value: value, error: error}
            )
          end
          context
        }
      )
      transition(
        from: :processing,
        on: :work_completed,
        to: :done,
        action: ->(context, event) {
          raise event.payload[:error] if event.payload[:error]

          context.merge(answer: event.payload[:value])
        }
      )
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {},
      config: {thread_id: "transition-async"}
    )
    Timeout.timeout(1) { entered.pop }

    expect(
      workflow.signal(
        thread_id: "transition-async",
        event: :start
      )
    ).to be(true)

    expect(wait_bounded(task).answer).to eq("async-result")
  end

  it "rejects pending, completed, and mapped Task return values" do
    pending = Phronomy::Task.deferred(name: "pending-transition-action")
    completed = completed_task("completed")
    mapped = completed_task("source").map { |value| value.upcase }

    [pending, completed, mapped].each do |returned_task|
      workflow = Phronomy::Workflow.define(context_class) do
        initial :source
        state :source

        transition(
          from: :source,
          to: :__finish__,
          action: ->(_context) { returned_task }
        )
      end

      expect {
        invoke_bounded(workflow, {})
      }.to raise_error(
        Phronomy::InvalidAsyncTransitionActionError,
        /:source --:state_completed--> :__finish__/
      )
    end
  end

  it "propagates action errors without running target entry callbacks" do
    order = []
    workflow = Phronomy::Workflow.define(context_class) do
      initial :source
      state :source
      state :target

      self.exit :source, ->(_context) {
        order << :exit
        nil
      }
      entry :target, ->(context) {
        order << :entry
        context
      }

      transition(
        from: :source,
        to: :target,
        action: ->(_context) {
          order << :action
          raise "transition failed"
        }
      )
      transition from: :target, to: :__finish__
    end

    expect {
      invoke_bounded(workflow, {})
    }.to raise_error(RuntimeError, "transition failed")
    expect(order).to eq(%i[exit action])
  end

  it "does not leak a selected action across later event dispatches" do
    entered = Queue.new
    workflow = Phronomy::Workflow.define(context_class) do
      initial :waiting
      state :waiting, action: ->(context) {
        entered << true
        context
      }
      state :done

      transition(
        from: :waiting,
        on: :mark,
        to: :waiting,
        action: ->(context) {
          context.merge(count: context.count + 1)
        }
      )
      transition(
        from: :waiting,
        on: :ignored,
        to: :waiting,
        guard: ->(_context) { false },
        action: ->(context) {
          context.merge(count: context.count + 100)
        }
      )
      transition from: :waiting, on: :finish, to: :done
      transition from: :done, to: :__finish__
    end

    task = workflow.invoke_async(
      {},
      config: {thread_id: "transition-selection-reset"}
    )
    Timeout.timeout(1) { entered.pop }

    expect(
      workflow.signal(
        thread_id: "transition-selection-reset",
        event: :mark
      )
    ).to be(true)
    expect(
      workflow.signal(
        thread_id: "transition-selection-reset",
        event: :ignored
      )
    ).to be(true)
    expect(
      workflow.signal(
        thread_id: "transition-selection-reset",
        event: :finish
      )
    ).to be(true)

    expect(wait_bounded(task).count).to eq(1)
  end

  it "autoloads the workflow action error hierarchy" do
    expect(
      Phronomy::InvalidAsyncEntryActionError <
        Phronomy::InvalidAsyncWorkflowActionError
    ).to be(true)
    expect(
      Phronomy::InvalidAsyncTransitionActionError <
        Phronomy::InvalidAsyncWorkflowActionError
    ).to be(true)
    expect(
      Phronomy::InvalidAsyncWorkflowActionError < Phronomy::Error
    ).to be(true)
  end
end
