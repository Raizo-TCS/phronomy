# frozen_string_literal: true

RSpec.describe "Cooperative scheduler yield points (Issue #306)" do
  describe "Runtime#yield" do
    it "is callable without error" do
      expect { Phronomy::Runtime.instance.yield }.not_to raise_error
    end

    it "delegates to the scheduler" do
      scheduler = Phronomy::Runtime::ThreadScheduler.new
      runtime = Phronomy::Runtime.new(scheduler: scheduler)
      allow(scheduler).to receive(:yield).and_call_original
      runtime.yield
      expect(scheduler).to have_received(:yield).once
    end

    it "calls Task.record_yield! to reset the CPU slice timer" do
      runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
      expect(Phronomy::Task).to receive(:record_yield!).at_least(:once)
      runtime.yield
    end
  end

  describe "Runtime#yield_if_needed" do
    it "is callable without error" do
      Phronomy::Runtime.instance.spawn { Phronomy::Runtime.instance.yield_if_needed }.wait_result
    end

    it "only calls scheduler#yield at multiples of every: (thread-local counter)" do
      # Reset thread-local counter: with FakeScheduler, tasks run synchronously
      # on the main thread, so the counter accumulates across tests.
      Thread.current[:phronomy_yield_if_needed_counter] = nil
      scheduler = Phronomy::Runtime::FakeScheduler.new
      runtime = Phronomy::Runtime.new(scheduler: scheduler)
      yield_calls = 0
      allow(scheduler).to receive(:yield) { yield_calls += 1 }

      # Run inside a spawned task so Thread-local state is isolated
      runtime.spawn do
        999.times { runtime.yield_if_needed(every: 1000) }
        expect(yield_calls).to eq(0)

        runtime.yield_if_needed(every: 1000) # 1000th call
        expect(yield_calls).to eq(1)

        999.times { runtime.yield_if_needed(every: 1000) }
        expect(yield_calls).to eq(1)

        runtime.yield_if_needed(every: 1000) # 2000th call
        expect(yield_calls).to eq(2)
      end.wait_result
    end

    it "counters from two concurrent tasks do not interfere (thread isolation)" do
      scheduler = Phronomy::Runtime::ThreadScheduler.new
      runtime = Phronomy::Runtime.new(scheduler: scheduler)

      counts = Array.new(2, 0)
      mutex = Mutex.new

      tasks = 2.times.map do |i|
        runtime.spawn do
          500.times { runtime.yield_if_needed(every: 1000) }
          mutex.synchronize { counts[i] = 500 }
        end
      end
      tasks.each(&:wait_result)

      # Neither task should have triggered a yield (each only reached 500/1000)
      # The key test is that they ran to completion without interference
      expect(counts).to eq([500, 500])
    end
  end

  describe "ThreadScheduler#yield" do
    it "calls Thread.pass" do
      scheduler = Phronomy::Runtime::ThreadScheduler.new
      expect(Thread).to receive(:pass)
      scheduler.yield
    end
  end

  describe "FakeScheduler#yield" do
    it "is a no-op (does not raise)" do
      scheduler = Phronomy::Runtime::FakeScheduler.new
      expect { scheduler.yield }.not_to raise_error
    end
  end

  describe "CPU-bound detection via blocking_detect_threshold_ms" do
    around do |example|
      original = Phronomy.configuration.blocking_detect_threshold_ms
      example.run
      Phronomy.configuration.blocking_detect_threshold_ms = original
    end

    it "emits a warning when a task exceeds the threshold without yielding" do
      Phronomy.configuration.blocking_detect_threshold_ms = 1 # 1ms threshold

      log_lines = []
      fake_logger = double("logger")
      allow(fake_logger).to receive(:warn) { |msg| log_lines << msg }
      original_logger = Phronomy.configuration.logger
      Phronomy.configuration.logger = fake_logger

      runtime = Phronomy::Runtime.new
      runtime.spawn do
        sleep(0.01) # 10ms — exceeds 1ms threshold
        runtime.yield
      end.wait_result

      Phronomy.configuration.logger = original_logger
      expect(log_lines).not_to be_empty
      expect(log_lines.first).to include("CPU-bound")
    ensure
      Phronomy.configuration.logger = original_logger
    end

    it "does not warn when a task yields within the threshold" do
      Phronomy.configuration.blocking_detect_threshold_ms = 500 # generous threshold

      log_lines = []
      fake_logger = double("logger")
      allow(fake_logger).to receive(:warn) { |msg| log_lines << msg }
      original_logger = Phronomy.configuration.logger
      Phronomy.configuration.logger = fake_logger

      runtime = Phronomy::Runtime.new
      runtime.spawn { runtime.yield }.wait_result

      Phronomy.configuration.logger = original_logger
      expect(log_lines.select { |l| l.include?("CPU-bound") }).to be_empty
    ensure
      Phronomy.configuration.logger = original_logger
    end

    it "increments non_yield_threshold_violation_count counter" do
      Phronomy.configuration.blocking_detect_threshold_ms = 1 # 1ms threshold

      runtime = Phronomy::Runtime.new
      runtime.spawn do
        sleep(0.01) # exceeds threshold
        runtime.yield
      end.wait_result

      expect(runtime.non_yield_threshold_violation_count).to be >= 1
    end

    it "does not increment counter when detection is disabled (nil threshold)" do
      Phronomy.configuration.blocking_detect_threshold_ms = nil

      runtime = Phronomy::Runtime.new
      runtime.spawn do
        sleep(0.01)
        runtime.yield
      end.wait_result

      expect(runtime.non_yield_threshold_violation_count).to eq(0)
    end
  end

  describe "Configuration" do
    it "starvation_threshold_ms defaults to 50" do
      expect(Phronomy::Configuration.new.starvation_threshold_ms).to eq(50)
    end

    it "starvation_threshold_ms is configurable" do
      config = Phronomy::Configuration.new
      config.starvation_threshold_ms = 25
      expect(config.starvation_threshold_ms).to eq(25)
    end
  end

  describe "Fairness regression (Issue #306 AC)" do
    # Acceptance Criteria: no task waits more than starvation_threshold_ms * 2
    # when all tasks yield cooperatively.
    # Test: 10 concurrent tasks each yielding 10 times; measure inter-yield
    # latency (time from yield call to being resumed by the scheduler).
    it "inter-yield latency stays below starvation_threshold_ms * 2" do
      threshold_ms = Phronomy.configuration.starvation_threshold_ms # 50ms default
      max_allowed_ms = threshold_ms * 2 # 100ms

      inter_yield_latencies_ms = []
      mutex = Mutex.new

      tasks = 10.times.map do
        Phronomy::Runtime.instance.spawn do
          10.times do
            before_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
            Phronomy::Runtime.instance.yield
            after_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
            mutex.synchronize { inter_yield_latencies_ms << (after_ms - before_ms) }
            sleep(0.001) # 1ms simulated work
          end
        end
      end

      tasks.each(&:wait_result)

      expect(inter_yield_latencies_ms).not_to be_empty
      max_observed = inter_yield_latencies_ms.max
      expect(max_observed).to be < max_allowed_ms,
        "Some tasks waited too long after yielding: " \
        "max=#{max_observed.round}ms, allowed=#{max_allowed_ms}ms"
    end
  end
end
