# frozen_string_literal: true

RSpec.describe "Deterministic Scheduler Infrastructure (Issue #310)" do
  include Phronomy::Testing::SchedulerHelpers

  # ─────────────────────────────────────────────────────────────────────────
  # Runtime::FakeScheduler extensions
  # ─────────────────────────────────────────────────────────────────────────
  describe Phronomy::Runtime::FakeScheduler do
    subject(:scheduler) { described_class.new }

    let(:runtime) do
      Phronomy::Runtime.new(scheduler: scheduler)
    end

    def run_task(name, &block)
      runtime.spawn(name: name, &block)
    end

    it "records :spawned and :completed events in order" do
      run_task("alpha") { 1 }
      types = scheduler.event_log.map { |e| e[:type] }
      expect(types).to include(:spawned, :completed)
      expect(types.index(:spawned)).to be < types.index(:completed)
    end

    it "records :cancelled events for tasks that raise CancellationError" do
      run_task("doomed") { raise Phronomy::CancellationError }
      types = scheduler.event_log.select { |e| e[:task_name] == "doomed" }.map { |e| e[:type] }
      expect(types).to include(:cancelled)
      expect(types).not_to include(:completed)
    end

    it "records :failed events for tasks that raise other errors" do
      run_task("broken") { raise "oops" }
      types = scheduler.event_log.select { |e| e[:task_name] == "broken" }.map { |e| e[:type] }
      expect(types).to include(:failed)
      expect(types).not_to include(:completed)
    end

    it "populates #tasks with all spawned tasks" do
      run_task("alpha") { 1 }
      run_task("beta") { 2 }
      names = scheduler.tasks.map { |t| t[:name] }
      expect(names).to include("alpha", "beta")
    end

    it "#tick returns self (no-op for synchronous backend)" do
      expect(scheduler.tick).to be(scheduler)
    end

    it "#tick_until returns true immediately when condition already holds" do
      ready = true
      result = scheduler.tick_until { ready }
      expect(result).to be(true)
    end

    it "#tick_until returns false when condition never holds within max_ticks" do
      result = scheduler.tick_until(max_ticks: 3) { false }
      expect(result).to be(false)
    end

    it "#pending_timers returns empty array without a clock" do
      expect(scheduler.pending_timers).to eq([])
    end

    context "with a FakeClock injected" do
      let(:clock) { Phronomy::Testing::FakeClock.new }

      before { scheduler.clock = clock }

      it "#pending_timers reflects the clock's pending callbacks" do
        clock.schedule(seconds: 5) { :a }
        clock.schedule(seconds: 10) { :b }
        timers = scheduler.pending_timers
        expect(timers.map { |t| t[:fire_at] }).to contain_exactly(5.0, 10.0)
      end

      it "timestamps events using the fake clock" do
        clock.advance(3.0)
        run_task("clocked") { 42 }
        at = scheduler.event_log.find { |e| e[:task_name] == "clocked" && e[:type] == :completed }&.dig(:at)
        expect(at).to eq(3.0)
      end
    end

    describe "#assert_order" do
      it "passes when tasks complete in the expected order" do
        run_task("first") { 1 }
        run_task("second") { 2 }
        expect { scheduler.assert_order("first", "second") }.not_to raise_error
      end

      it "raises ExpectationNotMetError when order is wrong" do
        # ImmediateBackend: first spawned = first completed, so reversed names fails
        run_task("alpha") { 1 }
        run_task("beta") { 2 }
        expect {
          scheduler.assert_order("beta", "alpha")
        }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      end

      it "raises ExpectationNotMetError when a named task never completed" do
        run_task("alpha") { 1 }
        expect {
          scheduler.assert_order("alpha", "missing")
        }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      end
    end

    describe "#assert_cancelled" do
      it "passes when the named task was cancelled" do
        run_task("victim") { raise Phronomy::CancellationError }
        expect { scheduler.assert_cancelled("victim") }.not_to raise_error
      end

      it "raises ExpectationNotMetError when the task was not cancelled" do
        run_task("ok-task") { 42 }
        expect {
          scheduler.assert_cancelled("ok-task")
        }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      end

      it "raises ExpectationNotMetError when the task name was never seen" do
        expect {
          scheduler.assert_cancelled("ghost")
        }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # FakeClock additions
  # ─────────────────────────────────────────────────────────────────────────
  describe Phronomy::Testing::FakeClock do
    subject(:clock) { described_class.new }

    describe "#next_timer_at" do
      it "returns nil when there are no pending callbacks" do
        expect(clock.next_timer_at).to be_nil
      end

      it "returns the earliest pending fire_at" do
        clock.at(10) { nil }
        clock.at(5) { nil }
        expect(clock.next_timer_at).to eq(5.0)
      end
    end

    describe "#advance_to_next_timer" do
      it "fires the next pending callback" do
        fired = false
        clock.at(7) { fired = true }
        clock.advance_to_next_timer
        expect(fired).to be(true)
        expect(clock.now).to eq(7.0)
      end

      it "raises when there are no pending timers" do
        expect { clock.advance_to_next_timer }.to raise_error(RuntimeError, /No pending timers/)
      end

      it "fires the earliest callback when multiple timers are pending" do
        order = []
        clock.at(10) { order << :ten }
        clock.at(3) { order << :three }
        clock.advance_to_next_timer
        expect(order).to eq([:three])
        expect(clock.now).to eq(3.0)
      end
    end

    describe "#pending_timer_entries" do
      it "returns empty array when no callbacks are pending" do
        expect(clock.pending_timer_entries).to eq([])
      end

      it "returns an entry for each pending callback sorted by fire_at" do
        clock.at(20) { nil }
        clock.at(5) { nil }
        entries = clock.pending_timer_entries
        expect(entries.map { |e| e[:fire_at] }).to eq([5.0, 20.0])
        expect(entries.all? { |e| e.key?(:description) }).to be(true)
      end

      it "does not include callbacks that have already fired" do
        clock.at(3) { nil }
        clock.at(8) { nil }
        clock.advance(5)
        expect(clock.pending_timer_entries.map { |e| e[:fire_at] }).to eq([8.0])
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Testing::SchedulerHelpers
  # ─────────────────────────────────────────────────────────────────────────
  describe Phronomy::Testing::SchedulerHelpers do
    it "replaces the global Runtime inside the block" do
      original = Phronomy::Runtime.instance
      with_fake_scheduler do |sched|
        expect(Phronomy::Runtime.instance).not_to be(original)
        expect(Phronomy::Runtime.instance.scheduler).to be(sched)
      end
    end

    it "restores the original Runtime after the block" do
      original = Phronomy::Runtime.instance
      with_fake_scheduler { |_sched| nil }
      expect(Phronomy::Runtime.instance).to be(original)
    end

    it "restores Runtime even if the block raises" do
      original = Phronomy::Runtime.instance
      begin
        with_fake_scheduler { raise "boom" }
      rescue RuntimeError
        nil
      end
      expect(Phronomy::Runtime.instance).to be(original)
    end

    it "injects the clock into the scheduler" do
      clock = Phronomy::Testing::FakeClock.new
      with_fake_scheduler(clock: clock) do |sched|
        expect(sched.clock).to be(clock)
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Acceptance Criterion: streaming tool cancellation ordering
  #
  # Verifies that a streaming tool task closing its token queue and raising
  # CancellationError is recorded as :cancelled BEFORE the parent task is
  # recorded as :completed in the event log.
  #
  # No sleep calls are used; ordering is proven via event_log indices alone.
  # ─────────────────────────────────────────────────────────────────────────
  describe "AC: streaming-tool cancellation precedes parent-task completion" do
    it "records the streaming-tool as cancelled before the parent completes" do
      token_queue = Phronomy::Concurrency::AsyncQueue.new

      with_fake_scheduler do |sched|
        runtime = Phronomy::Runtime.instance

        runtime.spawn(name: "parent-task") do
          # Spawn the streaming tool, which closes the token queue and signals
          # cancellation.  With ImmediateBackend the task runs synchronously,
          # so queue is closed before this spawn call returns.
          runtime.spawn(name: "streaming-tool") do
            token_queue.push("token-1")
            token_queue.push("token-2")
            token_queue.close
            raise Phronomy::CancellationError
          end

          # At this point the streaming-tool task has already completed as
          # :cancelled and the queue is closed.  Pop all tokens synchronously.
          tokens = []
          loop do
            val = begin
              token_queue.pop(timeout: 0)
            rescue ClosedQueueError
              nil
            end
            break if val.nil?
            tokens << val
          end
          tokens
        end

        # --- event ordering assertions (no sleep used anywhere) ---
        tool_cancelled_idx = sched.event_log.index { |e|
          e[:type] == :cancelled && e[:task_name] == "streaming-tool"
        }
        parent_completed_idx = sched.event_log.index { |e|
          e[:type] == :completed && e[:task_name] == "parent-task"
        }

        expect(tool_cancelled_idx).not_to be_nil
        expect(parent_completed_idx).not_to be_nil
        expect(tool_cancelled_idx).to be < parent_completed_idx

        # Helper assertion methods
        sched.assert_cancelled("streaming-tool")
      end
    end
  end
end
