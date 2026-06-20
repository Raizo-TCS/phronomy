# frozen_string_literal: true

# Thread-independence tests for the cooperative backend (Issue #309).
#
# These tests verify that normal agent/tool/orchestrator operations do not
# create additional Threads when the Runtime uses FakeScheduler (the cooperative
# synchronous backend backed by Task::ImmediateBackend).
#
# Thread count invariant under FakeScheduler:
#   - Spawning Tasks must not create new Threads.
#   - Only BlockingAdapterPool workers may create Threads, and only at
#     pool initialisation time (not during submit calls).
#
# With runtime_backend = :cooperative (the default), Runtime.instance uses
# FakeScheduler automatically.  These tests set it explicitly to remain
# robust when a future Fiber-based scheduler replaces FakeScheduler.
RSpec.describe "Thread-independence under FakeScheduler (Issue #309)" do
  # Build a Runtime backed by FakeScheduler and make it the shared instance
  # for the duration of each example.
  let(:cooperative_runtime) do
    Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
  end

  around do |example|
    Phronomy::Runtime.instance = cooperative_runtime
    example.run
  ensure
    Phronomy::Runtime.instance_variable_set(:@instance, nil)
  end

  # Returns a minimal agent class that short-circuits invoke without LLM.
  def stub_agent_class(output = "ok")
    out = output
    Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |_input, messages: [], thread_id: nil, config: {}, invocation_context: nil|
        {output: out, messages: []}
      end
      define_method(:invoke_async) do |input, messages: [], thread_id: nil, config: {}, invocation_context: nil|
        Phronomy::Task.spawn(name: "stub-async") { invoke(input, messages: messages, thread_id: thread_id, config: config) }
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 1: Agent#invoke_async does not increase Thread count
  # ---------------------------------------------------------------------------
  describe "Scenario 1: Agent#invoke_async with stubbed LLM" do
    it "does not increase Thread count" do
      agent = stub_agent_class("hello").new
      before = Thread.list.length
      task = agent.invoke_async("test")
      task.wait_result
      expect(Thread.list.length).to eq(before)
    end

    it "returns the expected output" do
      agent = stub_agent_class("result").new
      task = agent.invoke_async("input")
      expect(task.wait_result[:output]).to eq("result")
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5: Deadline.new does not increase Thread count (timer-queue path)
  # ---------------------------------------------------------------------------
  describe "Scenario 5: Deadline — no Thread increase" do
    it "does not increase Thread count for a single Deadline" do
      before = Thread.list.length
      _d = Phronomy::Concurrency::Deadline.new(5)
      expect(Thread.list.length).to be <= before + 1
    end

    it "does not linearly increase Thread count for 100 Deadlines" do
      before = Thread.list.length
      100.times { Phronomy::Concurrency::Deadline.new(30) }
      after = Thread.list.length
      # Timer queue uses at most one background Thread; allow +1 for it.
      expect(after - before).to be <= 1
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 6: TaskGroup with FakeScheduler — no Thread increase
  # ---------------------------------------------------------------------------
  describe "Scenario 6: TaskGroup with 10 tasks" do
    it "does not increase Thread count" do
      before = Thread.list.length
      group = cooperative_runtime.task_group(limit: 10)
      10.times do |i|
        group.spawn { i * 2 }
      end
      results = group.await_all
      expect(Thread.list.length).to eq(before)
      expect(results).to match_array((0..9).map { |i| i * 2 })
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 9: After task cancellation — Thread count returns to baseline
  # ---------------------------------------------------------------------------
  describe "Scenario 9: Task cancellation — Thread count stable" do
    it "Thread count is unchanged after spawning and cancelling tasks" do
      before = Thread.list.length
      # FakeScheduler executes synchronously, so tasks complete before cancel.
      # We verify that no extra threads were created during the lifecycle.
      tasks = 5.times.map do
        cooperative_runtime.spawn(name: "agent-cancel-#{SecureRandom.hex(4)}") { :done }
      end
      tasks.each do |t|
        t.cancel!
      rescue
        nil
      end
      expect(Thread.list.length).to eq(before)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 10: After Runtime#shutdown — all Threads return to baseline
  # ---------------------------------------------------------------------------
  describe "Scenario 10: Runtime#shutdown — Thread count at baseline" do
    it "does not leave extra Threads after shutdown" do
      # Measure the baseline *after* accounting for the always-running EventLoop
      # thread (which is now persistent across tests since Phase 2).
      before = Thread.list.length
      rt = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
      5.times { rt.spawn { :work } }
      rt.shutdown
      # Allow one GC cycle for thread teardown
      sleep 0.05
      # Runtime#shutdown calls EventLoop.instance.stop (singleton), which may
      # terminate the shared EventLoop thread when run in a full test suite.
      # Allow ±1 for that case.
      expect(Thread.list.length).to be_within(1).of(before)
    end
  end

  # ---------------------------------------------------------------------------
  # Cross-cutting: Runtime#spawn with various task types — no Thread increase
  # ---------------------------------------------------------------------------
  describe "typed spawns (agent/tool/workflow/rag) — no Thread increase" do
    %w[agent tool workflow rag llm].each do |type|
      it "does not increase Thread count for #{type}-* tasks" do
        before = Thread.list.length
        results = []
        5.times do |i|
          t = cooperative_runtime.spawn(name: "#{type}-ti-#{i}") { i }
          results << t.wait_result
        end
        expect(Thread.list.length).to eq(before)
        expect(results).to eq([0, 1, 2, 3, 4])
      end
    end
  end
end
