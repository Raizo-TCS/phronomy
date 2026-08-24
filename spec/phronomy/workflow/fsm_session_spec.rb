# frozen_string_literal: true

require "spec_helper"

# Unit tests for Phronomy::FSMSession (formerly Phronomy::Workflow::FSMSession).
# Phronomy::Workflow::FSMSession is kept as a compatibility alias.
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
RSpec.describe Phronomy::FSMSession do
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

  # Yields a FakeLoop and a fake_runtime duck-type object.
  # Pass fake_runtime as runtime: to build_session_for.
  def with_fake_loop
    fake = FakeLoop.new
    fake_runtime = double("fake_runtime", event_loop: fake, timer_queue: nil)
    yield fake, fake_runtime
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

  def build_test_execution(ctx, recursion_limit:)
    Phronomy::WorkflowRunner::Execution.new(
      context: ctx,
      workflow_instance_id: "test-thread",
      owner_token: Object.new.freeze,
      recursion_limit: recursion_limit,
      repository: nil,
      persist: false,
      expected_revision: nil
    )
  end

  def build_linear_session(ctx, runner:, recursion_limit: 25, fake_runtime: nil)
    execution = build_test_execution(ctx, recursion_limit: recursion_limit)
    runner.send(:build_session_for, execution: execution, runtime: fake_runtime || Phronomy::Runtime.instance)
  end

  def build_wait_session(ctx, runner:, recursion_limit: 25, fake_runtime: nil)
    execution = build_test_execution(ctx, recursion_limit: recursion_limit)
    runner.send(:build_session_for, execution: execution, runtime: fake_runtime || Phronomy::Runtime.instance)
  end

  def build_resume_session(ctx, runner:, resume_event:, resume_phase:, recursion_limit: 25, fake_runtime: nil)
    execution = build_test_execution(ctx, recursion_limit: recursion_limit)
    runner.send(:build_session_for,
      execution: execution,
      resume_event: resume_event,
      resume_phase: resume_phase,
      runtime: fake_runtime || Phronomy::Runtime.instance)
  end

  it "uses a fresh FSMSession identity reservation for each Workflow incarnation" do
    app = Phronomy::Workflow.define(ctx_class) do
      initial :waiting
      wait_state :waiting
    end
    runner = runner_from(app)
    ctx = ctx_class.new(value: 0)
    ctx.set_graph_metadata(workflow_instance_id: "identity-test")

    with_fake_loop do |_fake, fake_runtime|
      first = build_wait_session(ctx, runner: runner, fake_runtime: fake_runtime)
      second = build_wait_session(ctx, runner: runner, fake_runtime: fake_runtime)
      expect(first.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(second.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(second.id).not_to eq(first.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Linear workflow: auto-transitions drive the FSM to :finished
  # ---------------------------------------------------------------------------

  describe "linear workflow" do
    let(:app) do
      Phronomy::Workflow.define(ctx_class) do
        initial :step
        state :step
        entry :step, ->(s) { s.merge(value: s.value + 1) }
        transition from: :step, to: :__finish__
      end
    end

    it "posts :finished event with the final context after start" do
      runner = runner_from(app)
      ctx = ctx_class.new(value: 0)
      ctx.set_graph_metadata(workflow_instance_id: "t1")

      with_fake_loop do |fake, fake_runtime|
        session = build_linear_session(ctx, runner: runner, fake_runtime: fake_runtime)

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
        expect(finish_event.target_id).to eq(Phronomy::EventLoop::SYSTEM_CHANNEL_ID)
        expect(finish_event.payload[:fsm_session_id]).to eq(session.id)
        expect(finish_event.payload).not_to have_key(:session_id)
        expect(finish_event.payload[:result].value).to eq(1)
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
        entry :prepare, ->(s) { s.merge(value: s.value + 1) }
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :__finish__
      end
    end

    it "posts :halted with the context at the wait state" do
      runner = runner_from(app)
      ctx = ctx_class.new(value: 0)
      ctx.set_graph_metadata(workflow_instance_id: "t2")

      with_fake_loop do |fake, fake_runtime|
        session = build_wait_session(ctx, runner: runner, fake_runtime: fake_runtime)
        session.start

        # :state_completed was posted for :prepare; dispatch it
        if fake.events.last&.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t2", payload: nil))
        end

        halted_event = fake.events.find { |e| e.type == :halted }
        expect(halted_event).not_to be_nil
        expect(halted_event.payload[:result].phase).to eq(:awaiting)
        expect(halted_event.payload[:result].value).to eq(1)
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
        entry :prepare, ->(s) { s.merge(value: s.value + 10) }
        entry :confirm, ->(s) { s.merge(value: s.value + 100) }
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :confirm
        transition from: :confirm, to: :__finish__
      end
    end

    it "posts :finished after successfully firing the resume event" do
      runner = runner_from(app)
      # Simulate a context that has already passed through :prepare (value += 10).
      ctx = ctx_class.new(value: 10)
      ctx.set_graph_metadata(workflow_instance_id: "t3", phase: :awaiting)

      with_fake_loop do |fake, fake_runtime|
        session = build_resume_session(ctx, runner: runner, fake_runtime: fake_runtime,
          resume_event: :approve, resume_phase: :awaiting)
        session.start

        # :confirm entry fires, auto-transition → :state_completed posted
        if fake.events.last&.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t3", payload: nil))
        end

        finish_event = fake.events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        expect(finish_event.payload[:result].value).to eq(110)
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
      ctx.set_graph_metadata(workflow_instance_id: "t4")

      with_fake_loop do |fake, fake_runtime|
        session = build_linear_session(ctx, runner: runner, recursion_limit: 3, fake_runtime: fake_runtime)
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
        expect(error_event.payload[:result]).to be_a(Phronomy::RecursionLimitError)
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
      ctx.set_graph_metadata(workflow_instance_id: "t-merge-fresh")

      with_fake_loop do |fake, fake_runtime|
        session = build_linear_session(ctx, runner: runner, recursion_limit: 25, fake_runtime: fake_runtime)
        session.start

        if fake.events.last.type == :state_completed
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: "t-merge-fresh", payload: nil))
        end

        finish_event = fake.events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        # The action returned s.merge(value: 42); the finished payload must carry value: 42
        expect(finish_event.payload[:result].value).to eq(42)
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
      ctx.set_graph_metadata(workflow_instance_id: "t-merge-trans")

      with_fake_loop do |fake, fake_runtime|
        session = build_linear_session(ctx, runner: runner, recursion_limit: 25, fake_runtime: fake_runtime)
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
        expect(finish_event.payload[:result].tag).to eq("updated")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # handle_terminal_persistence_result edge cases.
  # ---------------------------------------------------------------------------
  describe "terminal persistence result handling" do
    let(:simple_workflow_for_persistence) do
      Phronomy::Workflow.define(ctx_class) do
        initial :step
        state :step
        transition from: :step, to: :__finish__
      end
    end

    it "ignores a persistence result when not in persisting_terminal state" do
      runner = runner_from(simple_workflow_for_persistence)
      ctx = ctx_class.new(value: 0)

      with_fake_loop do |_fake, fake_runtime|
        session = build_linear_session(ctx, runner: runner, fake_runtime: fake_runtime)
        # Force terminal_lifecycle_state to :running (default) so a persistence
        # result arriving out-of-order is silently discarded.
        bogus_result = Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :success, revision: 1, error: nil
        )
        session.handle(
          Phronomy::Event.new(
            type: :workflow_terminal_persistence_result,
            target_id: session.id,
            payload: bogus_result
          )
        )
        # No crash; lifecycle state unchanged (session has not started yet)
        expect(session.instance_variable_get(:@terminal_lifecycle_state)).to eq(:running)
      end
    end

    it "raises an error for an unknown persistence outcome" do
      runner = runner_from(simple_workflow_for_persistence)
      ctx = ctx_class.new(value: 0)

      with_fake_loop do |fake, fake_runtime|
        session = build_linear_session(ctx, runner: runner, fake_runtime: fake_runtime)
        session.instance_variable_set(:@terminal_lifecycle_state, :persisting_terminal)

        unknown_result = Phronomy::WorkflowRunner::WorkflowTerminalPersistenceResult.new(
          outcome: :bogus_unknown, revision: nil, error: nil
        )
        session.handle(
          Phronomy::Event.new(
            type: :workflow_terminal_persistence_result,
            target_id: session.id,
            payload: unknown_result
          )
        )
        # finish_with_error is called; session should post an :error terminal event
        error_event = fake.events.find { |e| e.type == :error }
        expect(error_event).not_to be_nil
        expect(error_event.payload[:result]).to be_a(Phronomy::Error)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # IdentityReservation: FSMSession accepts a pre-reserved identity.
  # ---------------------------------------------------------------------------
  describe "IdentityReservation" do
    let(:simple_workflow) do
      Phronomy::Workflow.define(ctx_class) do
        initial :step
        state :step
        transition from: :step, to: :__finish__
      end
    end

    it "uses the reserved id when a valid IdentityReservation is provided" do
      reservation = Phronomy::FSMSession.reserve_identity
      runner = runner_from(simple_workflow)
      ctx = ctx_class.new(value: 0)
      ctx.set_graph_metadata(workflow_instance_id: "reservation-test")

      with_fake_loop do |_fake, fake_runtime|
        session = Phronomy::FSMSession.new(
          context: ctx,
          context_metadata: {workflow_instance_id: "reservation-test"},
          entry_point: runner.instance_variable_get(:@entry_point),
          entry_actions: runner.instance_variable_get(:@entry_actions),
          auto_state_set: runner.instance_variable_get(:@auto_state_set),
          declared_states: runner.instance_variable_get(:@declared_states),
          wait_state_names: runner.instance_variable_get(:@wait_state_names),
          external_events: runner.instance_variable_get(:@external_events),
          phase_machine_class: runner.instance_variable_get(:@phase_machine_class),
          recursion_limit: 25,
          event_loop: fake_runtime.event_loop,
          identity_reservation: reservation
        )
        expect(session.id).to eq(reservation.fsm_session_id)
      end
    end

    it "raises ArgumentError when the identity_reservation is not an IdentityReservation" do
      runner = runner_from(simple_workflow)
      ctx = ctx_class.new(value: 0)

      with_fake_loop do |_fake, fake_runtime|
        expect do
          Phronomy::FSMSession.new(
            context: ctx,
            context_metadata: {},
            entry_point: runner.instance_variable_get(:@entry_point),
            entry_actions: runner.instance_variable_get(:@entry_actions),
            auto_state_set: runner.instance_variable_get(:@auto_state_set),
            declared_states: runner.instance_variable_get(:@declared_states),
            wait_state_names: runner.instance_variable_get(:@wait_state_names),
            external_events: runner.instance_variable_get(:@external_events),
            phase_machine_class: runner.instance_variable_get(:@phase_machine_class),
            recursion_limit: 25,
            event_loop: fake_runtime.event_loop,
            identity_reservation: Object.new
          )
        end.to raise_error(ArgumentError, /identity_reservation must come from FSMSession.reserve_identity/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # apply_context_event: handle_fsm_event returns a new WorkflowContext.
  # ---------------------------------------------------------------------------
  describe "context update via handle_fsm_event" do
    let(:ctx_with_event_handler) do
      Class.new do
        include Phronomy::WorkflowContext

        field :value, type: :replace, default: 0

        def handle_fsm_event(event)
          return :consume if event.type == :skip

          # Return a NEW context object; FSMSession must adopt it.
          return self.class.new(value: value + 100) if event.type == :enrich

          false
        end
      end
    end

    it "adopts the new context returned by handle_fsm_event" do
      app = Phronomy::Workflow.define(ctx_with_event_handler) do
        initial :waiting
        state :waiting
        state :done
        transition from: :waiting, on: :enrich, to: :done
        transition from: :done, to: :__finish__
      end

      runner = runner_from(app)
      ctx = ctx_with_event_handler.new(value: 1)
      ctx.set_graph_metadata(workflow_instance_id: "enrich-test")

      with_fake_loop do |fake, fake_runtime|
        session = build_wait_session(ctx, runner: runner, fake_runtime: fake_runtime)
        session.start

        # Drive the auto-transition manually if needed
        while (ev = fake.events.last) && ev.type == :state_completed
          fake.events.clear
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: session.id, payload: nil))
        end

        # Send :enrich — handle_fsm_event returns a NEW context (+100 to value)
        session.handle(Phronomy::Event.new(type: :enrich, target_id: session.id, payload: nil))

        while (ev = fake.events.last) && ev.type == :state_completed
          fake.events.clear
          session.handle(Phronomy::Event.new(type: :state_completed, target_id: session.id, payload: nil))
        end

        finish_event = fake.events.find { |e| e.type == :finished }
        expect(finish_event).not_to be_nil
        expect(finish_event.payload[:result].value).to eq(101)
      end
    end
  end
end
