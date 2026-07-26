# frozen_string_literal: true

require "spec_helper"

# Lifecycle invariant tests for Phronomy::FSMSession and Phronomy::EventLoop.
#
# EventLoop is now owned by Runtime; EventLoop.instance, EventLoop.reset!,
# EventLoop#start, and EventLoop#stop have been removed.
#
# Sections:
#   1. Double-completion guard
#   2. Unknown event handling
#   3. WorkflowRunner send_event
#   4. Shutdown propagation via Runtime#shutdown
#   5. Resource cleanup invariants (Runtime-owned)
#   6. P0 regression: dispatcher task handle retention (Issue #251)
RSpec.describe "Lifecycle invariants" do
  # ---------------------------------------------------------------------------
  # Minimal fake EventLoop that records posted events synchronously.
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

  # Minimal duck-type session. event_loop_ref must be set before registering.
  class FakeSlowSession
    attr_reader :id
    attr_accessor :event_loop_ref

    def initialize(id:, duration: 0.1)
      @id = id
      @duration = duration
      @event_loop_ref = nil
    end

    def start
      dur = @duration
      session_id = @id
      el = @event_loop_ref
      Thread.new do
        sleep dur
        el&.post(
          Phronomy::Event.new(
            type: :finished,
            target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {session_id: session_id, result: "done"}
          )
        )
      end
    end

    def handle(_event)
    end
  end

  # Yields a LifecycleFakeLoop and a fake_runtime duck-type object that returns
  # it from #event_loop.  Pass fake_runtime as runtime: to build_session_for.
  def with_fake_loop
    fake = LifecycleFakeLoop.new
    fake_runtime = double("fake_runtime", event_loop: fake, timer_queue: nil)
    yield fake, fake_runtime
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

      with_fake_loop do |fake, fake_runtime|
        session = runner.send(:build_session_for, context: ctx, recursion_limit: 25, runtime: fake_runtime)
        session.start
        drain_session(session, fake, thread_id: "lc-double-1")

        expect(session.instance_variable_get(:@done)).to be(true)
        finished_count_before = fake.events.count { |e| e.type == :finished }

        session.handle(Phronomy::Event.new(type: :state_completed, target_id: "lc-double-1", payload: nil))
        session.handle(Phronomy::Event.new(type: :some_custom_event, target_id: "lc-double-1", payload: nil))

        expect(fake.events.count { |e| e.type == :finished }).to eq(finished_count_before)
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

      with_fake_loop do |fake, fake_runtime|
        session = runner.send(:build_session_for, context: ctx, recursion_limit: 25, runtime: fake_runtime)
        session.start
        drain_session(session, fake, thread_id: "lc-double-2")

        expect(session.instance_variable_get(:@done)).to be(true)
        expect(fake.events.any? { |e| e.type == :halted }).to be(true)
        error_count_before = fake.events.count { |e| e.type == :error }

        session.handle(Phronomy::Event.new(type: :approve, target_id: "lc-double-2", payload: nil))
        session.handle(Phronomy::Event.new(type: :state_completed, target_id: "lc-double-2", payload: nil))

        expect(fake.events.count { |e| e.type == :error }).to eq(error_count_before)
      end
    end
  end

  # ===========================================================================
  # 2. Unknown event handling
  # ===========================================================================
  describe "unknown event handling (undeclared event type → :error posted)" do
    let(:wait_app) do
      Phronomy::Workflow.define(simple_ctx_class) do
        initial :prepare
        state :prepare
        wait_state :awaiting
        transition from: :prepare, to: :awaiting
        transition from: :awaiting, on: :approve, to: :__finish__
      end
    end

    it "posts :error when an undeclared event is fired at a running FSMSession" do
      runner = runner_from(wait_app)
      ctx = simple_ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "lc-unknown-1", phase: :awaiting)

      with_fake_loop do |fake, fake_runtime|
        session = runner.send(:build_session_for,
          context: ctx, recursion_limit: 25, runtime: fake_runtime,
          resume_event: :approve, resume_phase: :awaiting)

        session.instance_variable_set(:@done, false)
        session.instance_variable_set(:@current_state, :awaiting)
        session.instance_variable_set(:@tracker, session.send(:build_tracker, :awaiting))

        session.handle(Phronomy::Event.new(type: :unknown_event_xyz, target_id: "lc-unknown-1", payload: nil))

        err_ev = fake.events.find { |e| e.type == :error }
        expect(err_ev).not_to be_nil
        expect(err_ev.target_id).to eq(Phronomy::EventLoop::SYSTEM_CHANNEL_ID)
        expect(err_ev.payload[:result]).to be_a(Exception)
      end
    end

    it "sets @done = true after posting :error for an unknown event" do
      runner = runner_from(wait_app)
      ctx = simple_ctx_class.new(value: 0)
      ctx.set_graph_metadata(thread_id: "lc-unknown-2", phase: :awaiting)

      with_fake_loop do |fake, fake_runtime|
        session = runner.send(:build_session_for,
          context: ctx, recursion_limit: 25, runtime: fake_runtime,
          resume_event: :approve, resume_phase: :awaiting)

        session.instance_variable_set(:@done, false)
        session.instance_variable_set(:@current_state, :awaiting)
        session.instance_variable_set(:@tracker, session.send(:build_tracker, :awaiting))

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
  # 4. Shutdown propagation via Runtime#shutdown
  # ===========================================================================
  describe "shutdown propagation (Runtime#shutdown unblocks all waiting callers)" do
    let(:runtime) { Phronomy::Runtime.new }

    after do
      runtime.shutdown(timeout: 2)
    rescue
      nil
    end

    it "terminates the dispatcher cleanly when no sessions are active" do
      el = runtime.event_loop
      expect(el.task_alive?).to be(true)

      result = runtime.shutdown(timeout: 2)

      expect(result.cleanup_complete?).to be(true)
      expect(el.task_alive?).to be(false)
    end

    it "unblocks a waiting caller with an Exception when the dispatcher crashes" do
      el = runtime.event_loop
      cq = Thread::Queue.new

      # Directly inject a waiting entry to simulate an orphaned caller.
      el.instance_variable_get(:@waiting)["lc-shutdown-orphan"] = cq

      loop_task = el.instance_variable_get(:@task)
      loop_backend_thread = loop_task.instance_variable_get(:@backend).instance_variable_get(:@thread)
      sleep 0.001 while loop_backend_thread.status != "sleep"
      loop_backend_thread.raise(RuntimeError, "simulated loop crash")
      begin
        loop_task.join(2)
      rescue RuntimeError
        nil
      end

      received = nil
      t = Thread.new { received = cq.pop }
      t.join(1)

      expect(t.alive?).to be(false), "completion_queue.pop should have unblocked"
      expect(received).to be_a(Exception)
    end
  end

  # ===========================================================================
  # 5. Resource cleanup invariants
  # ===========================================================================
  describe "resource cleanup invariants" do
    let(:runtime) { Phronomy::Runtime.new }

    after do
      runtime.shutdown(timeout: 2)
    rescue
      nil
    end

    it "outstanding_sessions returns to zero after a completed session" do
      el = runtime.event_loop

      session = FakeSlowSession.new(id: "count-cleanup-test", duration: 0.05)
      session.event_loop_ref = el
      cq = el.register(session)
      cq.pop

      sleep 0.05
      expect(el.instance_variable_get(:@outstanding_sessions)).to eq(0)
    end

    it "Runtime.reset_default! returns a clean result after shutdown" do
      # Create an isolated Runtime, shut it down, then verify a fresh one is created.
      first_runtime = Phronomy::Runtime.new
      first_el = first_runtime.event_loop
      expect(first_el.task_alive?).to be(true)

      result = first_runtime.shutdown(timeout: 2)
      expect(result.cleanup_complete?).to be(true)
      expect(first_el.task_alive?).to be(false)

      second_runtime = Phronomy::Runtime.new
      second_el = second_runtime.event_loop
      expect(second_el).not_to be(first_el)
      expect(second_el.task_alive?).to be(true)
      begin
        second_runtime.shutdown(timeout: 2)
      rescue
        nil
      end
    end

    it "Runtime#shutdown(drain: true) waits for in-flight sessions" do
      el = runtime.event_loop

      started_q = Thread::Queue.new
      completed = []
      session_id = "drain-invariant-test"

      session = FakeSlowSession.new(id: session_id, duration: 0.15)
      session.event_loop_ref = el
      session.define_singleton_method(:start) do
        started_q.push(:started)
        el_ref = event_loop_ref
        Thread.new do
          sleep 0.15
          completed << :completed
          el_ref&.post(
            Phronomy::Event.new(
              type: :finished,
              target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
              payload: {session_id: session_id, result: "done"}
            )
          )
        end
      end

      el.register(session)
      started_q.pop

      result = runtime.shutdown(timeout: 5)

      expect(result.cleanup_complete?).to be(true)
      expect(completed).to include(:completed)
    end
  end

  # ===========================================================================
  # 6. Dispatcher task handle retention (P0 regression, Issue #251)
  #
  # Verifies that shutdown timeout does not lose the task handle, which was the
  # root cause of double-dispatch (P0 hotfix).
  # ===========================================================================
  describe "dispatcher task handle retention after timeout (P0 regression, Issue #251)" do
    let(:runtime) { Phronomy::Runtime.new }

    after do
      runtime.shutdown(timeout: 2)
    rescue
      nil
    end

    it "retains task handle and reports :cancel_timeout when cancel! does not terminate dispatcher" do
      el = runtime.event_loop

      started_q = Thread::Queue.new
      release = Thread::Queue.new
      session_id = "cancel-timeout-#{SecureRandom.hex(4)}"
      session = FakeSlowSession.new(id: session_id, duration: 60)
      session.event_loop_ref = el
      session.define_singleton_method(:start) do
        started_q.push(:started)
        release.pop
      end

      el.register(session)
      started_q.pop

      # Stub cancel! so the dispatcher never receives the cancel signal.
      task = el.instance_variable_get(:@task)
      allow(task).to receive(:cancel!).and_return(nil)

      result = runtime.shutdown(timeout: 0.05, cancel_grace: 0.05)

      expect(result.event_loop_status).to eq(:cancel_timeout)
      expect(result.cleanup_complete?).to be(false)
      expect(el.task_alive?).to be(true)
    ensure
      release&.push(:done)
    end

    it "retains task handle and reports :cancel_timeout when cancel! does not terminate dispatcher" do
      el = runtime.event_loop

      started_q = Thread::Queue.new
      release = Thread::Queue.new
      session_id = "cancel-timeout-#{SecureRandom.hex(4)}"
      session = FakeSlowSession.new(id: session_id, duration: 60)
      session.event_loop_ref = el
      session.define_singleton_method(:start) do
        started_q.push(:started)
        release.pop
      end

      el.register(session)
      started_q.pop

      task = el.instance_variable_get(:@task)
      allow(task).to receive(:cancel!).and_return(nil)

      # With cancel! stubbed as no-op, cancel_grace wait will expire with task alive.
      result = runtime.shutdown(timeout: 0.05, cancel_grace: 0.05)

      expect(result.event_loop_status).to eq(:cancel_timeout)
      expect(el.task_alive?).to be(true)
    ensure
      release&.push(:done)
    end

    it "Runtime.reset_default! raises and retains the singleton when cleanup is incomplete" do
      # Stub Runtime#shutdown to return an incomplete result without actually
      # running the full shutdown process (avoids caching the incomplete status).
      default_runtime = Phronomy::Runtime.instance
      incomplete_result = Phronomy::Runtime::ShutdownResult.new(
        runtime_outcome: :failed,
        cleanup_status: :incomplete,
        event_loop_status: :cancel_timeout,
        task_registry_status: :pending,
        error: nil
      )
      allow(default_runtime).to receive(:shutdown).and_return(incomplete_result)

      expect { Phronomy::Runtime.reset_default! }.to raise_error(Phronomy::RuntimeShutdownError)
      expect(Phronomy::Runtime.instance_variable_get(:@instance)).to be(default_runtime)
    ensure
      # Remove stub so spec_helper after-hook can cleanly reset_runtime!
      allow(default_runtime).to receive(:shutdown).and_call_original if default_runtime
    end
  end
end
