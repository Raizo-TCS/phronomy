# frozen_string_literal: true

require "spec_helper"

# Lifecycle invariant tests for Phronomy::Workflow::FSMSession and Phronomy::EventLoop.
#
# These specs validate four core lifecycle contracts:
#
#   1. Double-completion guard  — a completed (or halted) FSMSession silently
#      ignores any event posted after @done = true.
#   2. child_failed propagation — when an AgentFSM fails with a parent_id set,
#      :child_failed is posted to the parent FSMSession.  The parent can
#      declare an `on: :child_failed` transition to handle the error.
#   3. Unknown event handling  — an event whose type is not declared on the
#      phase machine causes FSMSession to call finish_with_error (posts :error)
#      rather than silently dying or corrupting state.
#   4. Shutdown propagation     — when EventLoop#stop is called while sessions
#      are still registered, pending completion queues are unblocked.

RSpec.describe "Lifecycle invariants" do
  # ---------------------------------------------------------------------------
  # Minimal fake EventLoop: captures posted events synchronously without
  # starting a background thread.  FSMSession calls EventLoop.instance so we
  # stub that to return this object.
  # ---------------------------------------------------------------------------
  class LifecycleFakeLoop
    attr_reader :events

    def initialize
      @events = []
    end

    def post(event)
      @events << event
    end
  end

  # Minimal duck-type session for EventLoop lifecycle tests.
  # Satisfies the #id / #start / #handle interface expected by EventLoop#register.
  # start spawns a thread that sleeps for +duration+ seconds then posts :finished.
  class FakeSlowSession
    attr_reader :id

    def initialize(id:, duration: 0.1)
      @id = id
      @duration = duration
    end

    def start
      dur = @duration
      session_id = @id
      Thread.new do
        sleep dur
        Phronomy::EventLoop.instance.post(
          Phronomy::Event.new(type: :finished, target_id: session_id, payload: "done")
        )
      end
    end

    def handle(_event)
    end
  end

  def with_fake_loop
    fake = LifecycleFakeLoop.new
    allow(Phronomy::EventLoop).to receive(:instance).and_return(fake)
    yield fake
  end

  def runner_from(workflow)
    workflow.instance_variable_get(:@runner)
  end

  # Drive a FSMSession forward using a FakeLoop until @done or no
  # :state_completed event is pending.
  def drain_session(session, fake, thread_id:, max_steps: 20)
    max_steps.times do
      break if session.instance_variable_get(:@done)
      ev = fake.events.last
      break unless ev&.type == :state_completed
      session.handle(Phronomy::Event.new(type: :state_completed, target_id: thread_id, payload: nil))
    end
  end

  let(:simple_ctx_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :value, type: :replace, default: 0
    end
  end

  # ===========================================================================
  # 1. Double-completion guard
  # ===========================================================================
  describe "double-completion guard (FSMSession ignores events after @done)" do
    # A linear single-state workflow that finishes immediately.
    let(:app) do
      Phronomy::Workflow.define(simple_ctx_class) do
        initial :step
        state :step
        entry :step, ->(s) { s.value = s.value + 1 }
        transition from: :step, to: :__finish__
      end
    end

    it "does not post a second :finished event when handle is called after completion" do
      runner = runner_from(app)
      ctx = simple_ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "lc-double-1")

      with_fake_loop do |fake|
        session = runner.send(:build_session_for, context: ctx, recursion_limit: 25)
        session.start
        drain_session(session, fake, thread_id: "lc-double-1")

        # Confirm the session finished.
        expect(session.instance_variable_get(:@done)).to be(true)
        finished_count_before = fake.events.count { |e| e.type == :finished }

        # Post a spurious :state_completed after completion.
        session.handle(Phronomy::Event.new(type: :state_completed, target_id: "lc-double-1", payload: nil))
        session.handle(Phronomy::Event.new(type: :some_custom_event, target_id: "lc-double-1", payload: nil))

        # No additional :finished events must have been posted.
        finished_count_after = fake.events.count { |e| e.type == :finished }
        expect(finished_count_after).to eq(finished_count_before)
      end
    end

    it "does not post :error when handle is called after a wait-state halt" do
      wait_app = Phronomy::Workflow.define(simple_ctx_class) do
        initial :prepare
        state :prepare
        wait_state :awaiting
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :__finish__
      end

      runner = runner_from(wait_app)
      ctx = simple_ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "lc-double-2")

      with_fake_loop do |fake|
        session = runner.send(:build_session_for, context: ctx, recursion_limit: 25)
        session.start
        drain_session(session, fake, thread_id: "lc-double-2")

        # Session must be halted (done) at the wait state.
        expect(session.instance_variable_get(:@done)).to be(true)
        expect(fake.events.any? { |e| e.type == :halted }).to be(true)

        error_count_before = fake.events.count { |e| e.type == :error }

        # Spurious event after halt must be silently dropped.
        session.handle(Phronomy::Event.new(type: :approve, target_id: "lc-double-2", payload: nil))
        session.handle(Phronomy::Event.new(type: :state_completed, target_id: "lc-double-2", payload: nil))

        error_count_after = fake.events.count { |e| e.type == :error }
        expect(error_count_after).to eq(error_count_before)
      end
    end
  end

  # ===========================================================================
  # 2. Unknown event handling
  # ===========================================================================
  describe "unknown event handling (undeclared event type → :error posted)" do
    # A workflow that halts at a wait state awaiting :approve only.
    # Firing any other event type is undeclared on the phase machine.
    let(:wait_app) do
      Phronomy::Workflow.define(simple_ctx_class) do
        initial :prepare
        state :prepare
        wait_state :awaiting
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :__finish__
      end
    end

    # A workflow with no external events at all — any event fired after
    # :state_completed is undeclared.
    let(:linear_app) do
      Phronomy::Workflow.define(simple_ctx_class) do
        initial :step
        state :step
        transition from: :step, to: :__finish__
      end
    end

    it "posts :error when an undeclared event is fired at a running FSMSession" do
      runner = runner_from(wait_app)
      ctx = simple_ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "lc-unknown-1", phase: :awaiting)

      with_fake_loop do |fake|
        # Build a resume session positioned at :awaiting, ready to receive events.
        session = runner.send(:build_session_for,
          context: ctx, recursion_limit: 25,
          resume_event: :approve, resume_phase: :awaiting)

        # Fire a completely unknown event instead of :approve.
        # We reset @done so the guard is bypassed and we can test the handler.
        session.instance_variable_set(:@done, false)
        session.instance_variable_set(:@current_state, :awaiting)
        session.instance_variable_set(:@tracker,
          session.send(:build_tracker, :awaiting))

        session.handle(Phronomy::Event.new(type: :unknown_event_xyz, target_id: "lc-unknown-1", payload: nil))

        err_ev = fake.events.find { |e| e.type == :error }
        expect(err_ev).not_to be_nil
        expect(err_ev.target_id).to eq("lc-unknown-1")
        # The payload must be an exception, not nil.
        expect(err_ev.payload).to be_a(Exception)
      end
    end

    it "sets @done = true after posting :error for an unknown event" do
      runner = runner_from(wait_app)
      ctx = simple_ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "lc-unknown-2", phase: :awaiting)

      with_fake_loop do |fake|
        session = runner.send(:build_session_for,
          context: ctx, recursion_limit: 25,
          resume_event: :approve, resume_phase: :awaiting)

        session.instance_variable_set(:@done, false)
        session.instance_variable_set(:@current_state, :awaiting)
        session.instance_variable_set(:@tracker,
          session.send(:build_tracker, :awaiting))

        session.handle(Phronomy::Event.new(type: :never_declared, target_id: "lc-unknown-2", payload: nil))

        expect(session.instance_variable_get(:@done)).to be(true)
      end
    end

    it "WorkflowRunner#send_event raises ArgumentError for unregistered event names" do
      app = Phronomy::Workflow.define(simple_ctx_class) do
        initial :prepare
        state :prepare
        wait_state :awaiting
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :__finish__
      end
      halted = app.invoke({value: 0}, config: {thread_id: "lc-unknown-3"})
      expect(halted.halted?).to be(true)

      expect do
        app.send_event(state: halted, event: :not_registered)
      end.to raise_error(ArgumentError, /Unknown event/)
    end
  end

  # ===========================================================================
  # 4. Shutdown propagation (EventLoop crash unblocks waiting callers)
  # ===========================================================================
  describe "shutdown propagation (EventLoop#stop unblocks all waiting callers)" do
    after do
      Phronomy::EventLoop.reset!
      Phronomy.reset_configuration!
    end

    it "stops the background task cleanly when no sessions are active" do
      Phronomy.configure { |c| c.event_loop = true }
      el = Phronomy::EventLoop.instance
      task = el.instance_variable_get(:@task)
      expect(task).to be_alive

      el.stop(timeout: 2)

      expect(task).not_to be_alive
      expect(el.instance_variable_get(:@task)).to be_nil
    end

    it "unblocks a waiting caller with an Exception when the loop crashes" do
      Phronomy.configure { |c| c.event_loop = true }
      el = Phronomy::EventLoop.instance

      # Register a fake session that never posts a completion event —
      # its completion_queue will block until the loop crashes.
      cq = Thread::Queue.new

      # Directly inject a waiting entry into the EventLoop internals so we can
      # simulate an unblocked caller without a real FSMSession.
      el.instance_variable_get(:@waiting)["lc-shutdown-orphan"] = cq

      # Kill the loop task to simulate a crash.
      # Task#join re-raises any exception the task terminated with, so we
      # suppress it here — we only need to wait for the task to actually die.
      loop_task = el.instance_variable_get(:@task)
      loop_backend_thread = loop_task.instance_variable_get(:@backend).instance_variable_get(:@thread)
      # Wait until the loop task is blocked in @queue.pop (status == "sleep").
      # Without this barrier, Thread#raise can be delivered before run_loop is
      # entered, meaning the rescue block in run_loop never runs and @waiting
      # is never flushed.
      sleep 0.001 while loop_backend_thread.status != "sleep"
      loop_backend_thread.raise(RuntimeError, "simulated loop crash")
      begin
        loop_task.join(2)
      rescue RuntimeError
        nil
      end

      # The waiting caller must be unblocked within a short window.
      received = nil
      t = Thread.new { received = cq.pop }
      t.join(1)

      expect(t.alive?).to be(false), "completion_queue.pop should have unblocked"
      expect(received).to be_a(Exception)
    end
  end

  # ===========================================================================
  # 5. Resource cleanup invariants (no leaked FSM entries or sessions)
  # ===========================================================================
  describe "resource cleanup invariants" do
    after do
      Phronomy::EventLoop.reset!
      Phronomy.reset_configuration!
    end

    it "@fsm_count returns to zero after a completed session" do
      # Verifies that @fsm_count decrements back to 0 after a session
      # completes and posts :finished to the EventLoop.
      Phronomy.configure { |c| c.event_loop = true }
      el = Phronomy::EventLoop.instance

      session = FakeSlowSession.new(id: "count-cleanup-test", duration: 0.05)
      cq = el.register(session)
      cq.pop  # block until EventLoop processes :finished and pushes to cq

      sleep 0.05
      expect(el.instance_variable_get(:@fsm_count)).to eq(0)
    end

    it "EventLoop.reset! nulls the singleton so the next call returns a fresh loop" do
      # Verifies that EventLoop.reset! fully tears down the background task and
      # clears @instance, so a subsequent EventLoop.instance starts cleanly with
      # no residual state from the previous run.
      Phronomy.configure { |c| c.event_loop = true }
      first = Phronomy::EventLoop.instance
      first_task = first.instance_variable_get(:@task)
      expect(first_task).to be_alive

      Phronomy::EventLoop.reset!

      expect(first_task).not_to be_alive
      expect(Phronomy::EventLoop.instance_variable_get(:@instance)).to be_nil

      second = Phronomy::EventLoop.instance
      expect(second).not_to be(first)
      expect(second.instance_variable_get(:@fsm_count)).to eq(0)
      expect(second.instance_variable_get(:@task)).to be_alive
    end

    it "EventLoop#stop(drain: true) waits for in-flight sessions before the loop thread exits" do
      # Verifies that stop(drain: true) blocks until @fsm_count reaches 0,
      # meaning all queued sessions have completed before the loop shuts down.
      Phronomy.configure { |c| c.event_loop = true }
      el = Phronomy::EventLoop.instance

      started_q = Thread::Queue.new
      completed = []
      session_id = "drain-invariant-test"

      # Custom session that signals start and records completion.
      session = FakeSlowSession.new(id: session_id, duration: 0.15)
      session.define_singleton_method(:start) do
        started_q.push(:started)
        Thread.new do
          sleep 0.15
          completed << :completed
          Phronomy::EventLoop.instance.post(
            Phronomy::Event.new(type: :finished, target_id: session_id, payload: "done")
          )
        end
      end

      el.register(session)
      started_q.pop  # block until session has started (guarantees @fsm_count > 0)

      status = el.stop(drain: true, timeout: 5, force_kill: true)

      expect(status).to eq(:clean)
      expect(completed).to include(:completed)
    end
  end

  # ===========================================================================
  # 6. Task-leak detection after timeout-forced shutdown (Issue #251)
  #
  # When stop(force_kill: true) fires before an in-flight session completes,
  # the background loop task must be dead and @task must be nil so that a
  # subsequent EventLoop.instance starts without contaminated state.
  # ===========================================================================
  describe "thread leak after timeout-forced shutdown (Issue #251)" do
    # These tests start a real agent IO thread (sleep 10) and cancel it via
    # EventLoop#stop(force_kill: true).  Concurrent execution is required, so
    # force the :thread backend so Runtime.instance spawns real threads.
    around do |ex|
      Phronomy.configure { |c| c.runtime_backend = :thread }
      Phronomy::Runtime.instance_variable_set(:@instance, nil)
      ex.run
    ensure
      Phronomy.reset_configuration!
      Phronomy::Runtime.instance_variable_set(:@instance, nil)
    end

    after do
      Phronomy::EventLoop.reset!
      Phronomy.reset_configuration!
    end

    it "loop task is dead and @task is nil after stop with an in-flight session" do
      # Verifies that stop (regardless of :clean or :force_killed outcome) always
      # sets @task to nil and leaves the background task no longer alive,
      # even when a session IO thread is still running at shutdown time.
      Phronomy.configure { |c| c.event_loop = true }
      el = Phronomy::EventLoop.instance
      loop_task = el.instance_variable_get(:@task)
      expect(loop_task).to be_alive

      # Register a session that sleeps far longer than the stop timeout.
      started_q = Thread::Queue.new
      session_id = "leak-force-kill-#{SecureRandom.hex(4)}"
      session = FakeSlowSession.new(id: session_id, duration: 10)
      session.define_singleton_method(:start) do
        started_q.push(:started)
        Thread.new do
          sleep 10
          Phronomy::EventLoop.instance.post(
            Phronomy::Event.new(type: :finished, target_id: session_id, payload: "done")
          )
        end
      end

      el.register(session)
      started_q.pop  # ensure the IO thread is running before we call stop

      status = el.stop(timeout: 2, force_kill: true)

      expect([:clean, :force_killed]).to include(status)
      expect(loop_task).not_to be_alive
      expect(el.instance_variable_get(:@task)).to be_nil
    end

    it "a subsequent EventLoop.instance starts with a fresh task after force_kill" do
      # Verifies that EventLoop.reset! followed by .instance creates a new,
      # alive task — no residual contamination from the killed instance.
      Phronomy.configure { |c| c.event_loop = true }
      el_first = Phronomy::EventLoop.instance
      first_task = el_first.instance_variable_get(:@task)

      started_q = Thread::Queue.new
      session_id = "leak-reset-#{SecureRandom.hex(4)}"
      session = FakeSlowSession.new(id: session_id, duration: 10)
      session.define_singleton_method(:start) do
        started_q.push(:started)
        Thread.new do
          sleep 10
          Phronomy::EventLoop.instance.post(
            Phronomy::Event.new(type: :finished, target_id: session_id, payload: "done")
          )
        end
      end

      el_first.register(session)
      started_q.pop

      el_first.stop(timeout: 0.1, force_kill: true)
      Phronomy::EventLoop.reset!

      # After reset, a new instance must have its own alive task.
      el_second = Phronomy::EventLoop.instance
      second_task = el_second.instance_variable_get(:@task)
      expect(second_task).to be_alive
      expect(second_task).not_to be(first_task)
      expect(el_second.instance_variable_get(:@fsm_count)).to eq(0)
    end
  end
end
