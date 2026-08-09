# frozen_string_literal: true

# Thread-independence tests for FakeScheduler (Issue #309).
#
# These tests verify that normal agent/tool/orchestrator operations do not
# create additional Threads when the Runtime uses FakeScheduler, the immediate
# synchronous scheduler used explicitly by these tests.
#
# Thread count invariant under FakeScheduler:
#   - Spawning Tasks must not create new Threads.
#   - Only BlockingAdapterPool workers may create Threads, and only at
#     pool initialisation time (not during submit calls).
RSpec.describe "Thread-independence under FakeScheduler (Issue #309)" do
  let(:cooperative_runtime) do
    Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
  end

  around do |example|
    previous = Phronomy::Runtime.replace_default_for_test(cooperative_runtime)
    example.run
  ensure
    Phronomy::Runtime.restore_default_for_test(previous)
  end

  def stub_agent_class(output = "ok")
    out = output
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-101", version: 1
      define_method(:invoke) do |_input, thread_id: nil, config: {}, invocation_context: nil, on_event: nil|
        {output: out, messages: []}
      end
      define_method(:invoke_async) do |input, thread_id: nil, config: {}, invocation_context: nil, on_tool_approval_required: nil, on_event: nil|
        Phronomy::Task.spawn(name: "stub-async") do
          invoke(
            input,
            thread_id: thread_id,
            config: config,
            invocation_context: invocation_context,
            on_event: on_event
          )
        end
      end
    end
  end

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
      expect(after - before).to be <= 1
    end
  end

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

  describe "Scenario 9: Task cancellation — Thread count stable" do
    it "Thread count is unchanged after spawning and cancelling tasks" do
      before = Thread.list.length
      tasks = 5.times.map do
        cooperative_runtime.spawn(name: "agent-cancel-#{SecureRandom.hex(4)}") { :done }
      end
      tasks.each do |task|
        task.cancel!
      rescue
        nil
      end
      expect(Thread.list.length).to eq(before)
    end
  end

  describe "Scenario 10: Runtime#shutdown — Thread count at baseline" do
    it "does not leave extra Threads after shutdown" do
      before = Thread.list.length
      runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
      5.times { runtime.spawn { :work } }
      runtime.shutdown
      sleep 0.05
      expect(Thread.list.length).to be_within(1).of(before)
    end
  end

  describe "typed spawns (agent/tool/workflow/rag) — no Thread increase" do
    %w[agent tool workflow rag llm].each do |type|
      it "does not increase Thread count for #{type}-* tasks" do
        before = Thread.list.length
        results = []
        5.times do |i|
          task = cooperative_runtime.spawn(name: "#{type}-ti-#{i}") { i }
          results << task.wait_result
        end
        expect(Thread.list.length).to eq(before)
        expect(results).to eq([0, 1, 2, 3, 4])
      end
    end
  end
end
