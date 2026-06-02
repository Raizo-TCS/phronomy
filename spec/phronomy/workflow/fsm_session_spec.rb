# frozen_string_literal: true

require "spec_helper"

# Unit tests for Phronomy::Workflow::FSMSession.
#
# FSMSession is an internal class orchestrated by EventLoop.
# These tests exercise its behaviour by injecting a fake EventLoop double
# and building minimal WorkflowRunner internals via Phronomy::Workflow.
#
# Testing strategy:
#   1. Build a Workflow via the public DSL.
#   2. Extract WorkflowRunner internals via instance_variable_get (acceptable
#      for unit tests of internal classes).
#   3. Inject a fake EventLoop (FakeLoop) to capture posted events without
#      requiring a real background thread.
#   4. Assert the events posted by FSMSession in response to each scenario.
RSpec.describe Phronomy::Workflow::FSMSession do
  # Minimal fake event loop that captures all posted events.
  # Does not start a thread — events are captured synchronously.
  class FakeLoop
    attr_reader :events

    def initialize
      @events = []
    end

    def post(event)
      @events << event
    end
  end

  # Replace EventLoop.instance with a FakeLoop for the duration of the test.
  def with_fake_loop
    fake = FakeLoop.new
    allow(Phronomy::EventLoop).to receive(:instance).and_return(fake)
    yield fake
  end

  # Build a WorkflowRunner from a Workflow definition and return it.
  def runner_from(workflow)
    workflow.instance_variable_get(:@runner)
  end

  let(:ctx_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers: build common session configurations via WorkflowRunner
  # ---------------------------------------------------------------------------

  def build_linear_session(ctx, runner:, recursion_limit: 25)
    runner.send(:build_session_for, context: ctx, recursion_limit: recursion_limit)
  end

  def build_wait_session(ctx, runner:, recursion_limit: 25)
    runner.send(:build_session_for, context: ctx, recursion_limit: recursion_limit)
  end

  def build_resume_session(ctx, runner:, resume_event:, resume_phase:, recursion_limit: 25)
    runner.send(:build_session_for,
      context: ctx, recursion_limit: recursion_limit,
      resume_event: resume_event, resume_phase: resume_phase)
  end

  # ---------------------------------------------------------------------------
  # Linear workflow: auto-transitions drive the FSM to :finished
  # ---------------------------------------------------------------------------

  describe "linear workflow" do
    let(:app) do
      Phronomy::Workflow.define(ctx_class) do
        initial :step
        state :step
        entry :step, ->(s) { s.value = s.value + 1 }
        transition from: :step, to: :__finish__
      end
    end

    it "posts :finished event with the final context after start" do
      runner = runner_from(app)
      ctx = ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "t1")

      with_fake_loop do |fake|
        session = build_linear_session(ctx, runner: runner)

        # FSMSession#start drives the whole linear graph synchronously since the
        # :state_completed event is posted and re-handled in the same call chain
        # only when there IS a real EventLoop. With FakeLoop we must drive it
        # manually to simulate the EventLoop dispatch.

        # Step 1 — call start: entry action fires, :state_completed posted
        session.start

        events = fake.events
        expect(%i[finished state_completed]).to include(events.last.type)

        # If :state_completed was posted, simulate the EventLoop dispatching it
        if fake.events.last.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t1", payload: nil))
          events = fake.events
        end

        finish_event = events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        expect(finish_event.target_id).to eq("t1")
        expect(finish_event.payload.value).to eq(1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Wait-state workflow: FSMSession posts :halted
  # ---------------------------------------------------------------------------

  describe "wait state" do
    let(:app) do
      Phronomy::Workflow.define(ctx_class) do
        initial :prepare
        state :prepare
        wait_state :awaiting
        entry :prepare, ->(s) { s.value = s.value + 1 }
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :__finish__
      end
    end

    it "posts :halted with the context at the wait state" do
      runner = runner_from(app)
      ctx = ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "t2")

      with_fake_loop do |fake|
        session = build_wait_session(ctx, runner: runner)
        session.start

        # :state_completed was posted for :prepare; dispatch it
        if fake.events.last&.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t2", payload: nil))
        end

        halted_event = fake.events.find { |e| e.type == :halted }
        expect(halted_event).not_to be_nil
        expect(halted_event.payload.phase).to eq(:awaiting)
        expect(halted_event.payload.value).to eq(1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Resume: firing an external event from a halted wait state
  # ---------------------------------------------------------------------------

  describe "resume from wait state" do
    let(:app) do
      Phronomy::Workflow.define(ctx_class) do
        initial :prepare
        state :prepare
        wait_state :awaiting
        state :confirm
        entry :prepare, ->(s) { s.value = s.value + 10 }
        entry :confirm, ->(s) { s.value = s.value + 100 }
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :confirm
        transition from: :confirm, to: :__finish__
      end
    end

    it "posts :finished after successfully firing the resume event" do
      runner = runner_from(app)
      # Simulate a context that has already passed through :prepare (value += 10).
      ctx = ctx_class.new(value: 10)
      ctx.set_graph_metadata(thread_id: "t3", phase: :awaiting)

      with_fake_loop do |fake|
        session = build_resume_session(ctx, runner: runner,
          resume_event: :approve, resume_phase: :awaiting)
        session.start

        # :confirm entry fires, auto-transition → :state_completed posted
        if fake.events.last&.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t3", payload: nil))
        end

        finish_event = fake.events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        expect(finish_event.payload.value).to eq(110)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # RecursionLimitError: posts :error when the limit is exceeded
  # ---------------------------------------------------------------------------

  describe "recursion limit" do
    # Two states that cycle endlessly: :a → :b → :a → :b → ...
    # state_machines transitions :a → :b and :b → :a, so the FSM never
    # reaches FINISH without hitting the recursion limit.
    let(:cycling_app) do
      Phronomy::Workflow.define(ctx_class) do
        initial :step_a
        state :step_a
        state :step_b
        transition from: :step_a, to: :step_b
        transition from: :step_b, to: :step_a
      end
    end

    it "posts :error with a RecursionLimitError when the limit is reached" do
      runner = runner_from(cycling_app)
      ctx = ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "t4")

      with_fake_loop do |fake|
        session = build_linear_session(ctx, runner: runner, recursion_limit: 3)
        session.start

        # Drive the cycling loop manually.
        # Each :state_completed invocation increments @step.
        # RecursionLimitError fires when @step >= recursion_limit (3).
        # Requires (limit + 1) = 4 dispatches:
        #   start:  @step=0, :step_a entry fires, advance → :state_completed posted
        #   iter 1: @step=0<3, a→b, @step=1, advance → :state_completed
        #   iter 2: @step=1<3, b→a, @step=2, advance → :state_completed
        #   iter 3: @step=2<3, a→b, @step=3, advance → :state_completed
        #   iter 4: @step=3>=3, RecursionLimitError → :error posted
        6.times do
          break if session.instance_variable_get(:@done)
          ev = fake.events.last
          break unless ev&.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t4", payload: nil))
        end

        error_event = fake.events.find { |e| e.type == :error }
        expect(error_event).not_to be_nil
        expect(error_event.payload).to be_a(Phronomy::RecursionLimitError)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Regression test for Issue #107: FSMSession ignores the WorkflowContext
  # returned by entry actions, so s.merge(...) style actions have no effect
  # in EventLoop mode.
  # ---------------------------------------------------------------------------
  describe "entry action return value is adopted as new context (Issue #107)" do
    let(:ctx_class_merge) do
      Class.new do
        include Phronomy::WorkflowContext

        field :value, type: :replace, default: 0
        field :tag, type: :replace, default: ""
      end
    end

    it "reflects field updates when the fresh-start entry action returns s.merge(...)" do
      app = Phronomy::Workflow.define(ctx_class_merge) do
        initial :step
        state :step, action: ->(s) { s.merge(value: 42) }
        transition from: :step, to: :__finish__
      end

      runner = runner_from(app)
      ctx = ctx_class_merge.new(value: 0, tag: "before")
      ctx.set_graph_metadata(thread_id: "t-merge-fresh")

      with_fake_loop do |fake|
        session = runner.send(:build_session_for, context: ctx, recursion_limit: 25)
        session.start

        if fake.events.last.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t-merge-fresh", payload: nil))
        end

        finish_event = fake.events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        # The action returned s.merge(value: 42); the finished payload must carry value: 42
        expect(finish_event.payload.value).to eq(42)
      end
    end

    it "reflects field updates when a transition-target entry action returns s.merge(...)" do
      app = Phronomy::Workflow.define(ctx_class_merge) do
        initial :first
        state :first
        entry :first, ->(_s) {} # no-op; does not return a WorkflowContext
        transition from: :first, to: :second

        state :second
        entry :second, ->(s) { s.merge(tag: "updated") }
        transition from: :second, to: :__finish__
      end

      runner = runner_from(app)
      ctx = ctx_class_merge.new(value: 0, tag: "original")
      ctx.set_graph_metadata(thread_id: "t-merge-trans")

      with_fake_loop do |fake|
        session = runner.send(:build_session_for, context: ctx, recursion_limit: 25)
        session.start

        # Drive the event loop manually. Use @done as the termination guard instead
        # of object identity, because Event is a Data value object and two
        # :state_completed events with the same fields compare equal via ==.
        while (ev = fake.events.last) && ev.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t-merge-trans", payload: nil))
          break if session.instance_variable_get(:@done)
        end

        finish_event = fake.events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        # The second-state entry action returned s.merge(tag: "updated")
        expect(finish_event.payload.tag).to eq("updated")
      end
    end
  end
end
