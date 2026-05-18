# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::TeamCoordinator do
  # Builds a stub worker agent class. The optional block receives (input, messages)
  # and returns the output string. When omitted, returns "ok".
  def stub_worker(&response_block)
    Class.new(Phronomy::Agent::Base) do
      define_method(:invoke) do |input, config: {}|
        msgs_in = Array(config[:messages])
        output = response_block ? response_block.call(input, msgs_in) : "ok"
        new_msgs = msgs_in + [{role: "user", content: input}, {role: "assistant", content: output}]
        {output: output, messages: new_msgs}
      end
    end
  end

  # Stubs the private #run_coordinator to directly enqueue a list of task descriptions,
  # bypassing any LLM calls.
  def seed_tasks(team, descriptions)
    allow(team).to receive(:run_coordinator) do |_input, task_queue|
      descriptions.each_with_index do |desc, i|
        task_queue << {id: i + 1, description: desc, metadata: nil, enqueued_at: Time.now}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DSL
  # ---------------------------------------------------------------------------

  describe "DSL" do
    describe ".coordinator_model" do
      it "stores and reads back the coordinator model" do
        klass = Class.new(described_class) { coordinator_model "gpt-4o" }
        expect(klass._coordinator_model).to eq("gpt-4o")
      end

      it "returns nil when not configured" do
        klass = Class.new(described_class)
        expect(klass._coordinator_model).to be_nil
      end
    end

    describe ".coordinator_instructions" do
      it "stores and reads back the instructions" do
        klass = Class.new(described_class) { coordinator_instructions "Plan tasks." }
        expect(klass._coordinator_instructions).to eq("Plan tasks.")
      end
    end

    describe ".pool" do
      it "stores pool_size, worker_agent, and on_error" do
        worker = stub_worker
        klass = Class.new(described_class) { pool size: 4, agent: worker, on_error: :skip }
        expect(klass._pool_size).to eq(4)
        expect(klass._worker_agent).to eq(worker)
        expect(klass._on_error).to eq(:skip)
      end

      it "defaults on_error to :raise" do
        klass = Class.new(described_class) { pool size: 1, agent: Class.new }
        expect(klass._on_error).to eq(:raise)
      end

      it "defaults pool_size to 1 when .pool is never called" do
        klass = Class.new(described_class)
        expect(klass._pool_size).to eq(1)
      end
    end

    describe ".aggregate" do
      it "stores the aggregator block" do
        blk = ->(a) { a }
        klass = Class.new(described_class)
        klass.aggregate(&blk)
        expect(klass._aggregator).to eq(blk)
      end
    end

    describe ".schedule" do
      it "stores the scheduler block" do
        blk = ->(w) { w.first }
        klass = Class.new(described_class)
        klass.schedule(&blk)
        expect(klass._scheduler).to eq(blk)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #invoke
  # ---------------------------------------------------------------------------

  describe "#invoke" do
    it "raises ArgumentError when pool :agent is not configured" do
      klass = Class.new(described_class)
      expect { klass.new.invoke("task") }.to raise_error(ArgumentError, /pool :agent/)
    end

    it "returns the raw assignments array when no aggregate block is set" do
      worker_class = stub_worker { |input, _| "done: #{input}" }
      klass = Class.new(described_class) { pool size: 1, agent: worker_class }
      team = klass.new
      seed_tasks(team, ["Task A", "Task B"])

      result = team.invoke("run")

      expect(result).to be_an(Array)
      expect(result.size).to eq(2)
      expect(result.map { |a| a[:result] }).to contain_exactly("done: Task A", "done: Task B")
    end

    it "passes team_input as a string to the coordinator" do
      worker_class = stub_worker
      klass = Class.new(described_class) { pool size: 1, agent: worker_class }
      team = klass.new

      received_input = nil
      allow(team).to receive(:run_coordinator) do |input, task_queue|
        received_input = input
        task_queue << {id: 1, description: "T1", metadata: nil, enqueued_at: Time.now}
      end

      team.invoke("migrate the repo")
      expect(received_input).to eq("migrate the repo")
    end

    it "calls the aggregate block with assignments and returns its result" do
      worker_class = stub_worker { "ok" }
      klass = Class.new(described_class) do
        pool size: 1, agent: worker_class
        aggregate { |a| {total: a.size} }
      end
      team = klass.new
      seed_tasks(team, ["T1", "T2", "T3"])

      expect(team.invoke("run")).to eq({total: 3})
    end

    it "carries accumulated messages forward to each successive worker invocation" do
      received_messages = []
      worker_class = stub_worker do |_input, msgs_in|
        received_messages << msgs_in.dup
        "ok"
      end
      klass = Class.new(described_class) { pool size: 1, agent: worker_class }
      team = klass.new
      seed_tasks(team, ["T1", "T2", "T3"])
      team.invoke("run")

      # First task: no prior messages
      expect(received_messages[0]).to be_empty
      # Second task: messages from the first invocation (user + assistant = 2)
      expect(received_messages[1].size).to eq(2)
      # Third task: messages from first + second invocations (4 total)
      expect(received_messages[2].size).to eq(4)
    end

    context "with a pool of N workers and M > N tasks" do
      it "distributes tasks across all workers" do
        worker_class = stub_worker { "done" }
        klass = Class.new(described_class) { pool size: 2, agent: worker_class }
        team = klass.new
        seed_tasks(team, ["T1", "T2", "T3", "T4"])

        assignments = team.invoke("run")
        worker_counts = assignments.group_by { |a| a[:worker] }.transform_values(&:count)

        expect(worker_counts.values.sum).to eq(4)
        expect(worker_counts.keys.sort).to eq([0, 1])
        expect(worker_counts.values).to all(eq(2))
      end
    end

    context "error handling" do
      it "re-raises worker exceptions by default (on_error: :raise)" do
        failing = Class.new(Phronomy::Agent::Base) do
          define_method(:invoke) { |_input, config: {}| raise "worker exploded" }
        end
        klass = Class.new(described_class) { pool size: 1, agent: failing }
        team = klass.new
        seed_tasks(team, ["T1"])

        expect { team.invoke("run") }.to raise_error(RuntimeError, "worker exploded")
      end

      it "records failures and continues remaining tasks when on_error: :skip" do
        mixed = Class.new(Phronomy::Agent::Base) do
          define_method(:invoke) do |input, config: {}|
            raise "boom" if input == "T1"
            {output: "ok:#{input}", messages: []}
          end
        end
        klass = Class.new(described_class) { pool size: 1, agent: mixed, on_error: :skip }
        team = klass.new
        seed_tasks(team, ["T1", "T2"])

        assignments = team.invoke("run")
        failed = assignments.select { |a| a[:result].nil? }
        succeeded = assignments.reject { |a| a[:result].nil? }

        expect(failed.size).to eq(1)
        expect(failed.first[:error].message).to eq("boom")
        expect(succeeded.size).to eq(1)
        expect(succeeded.first[:result]).to eq("ok:T2")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #stream
  # ---------------------------------------------------------------------------

  describe "#stream" do
    it "yields :task_completed events for each successful task" do
      worker_class = stub_worker { |input, _| "done: #{input}" }
      klass = Class.new(described_class) { pool size: 1, agent: worker_class }
      team = klass.new
      seed_tasks(team, ["A", "B"])

      events = []
      team.stream("run") { |e| events << e }

      expect(events.size).to eq(2)
      expect(events.map { |e| e[:type] }).to all(eq(:task_completed))
      expect(events.map { |e| e[:result] }).to contain_exactly("done: A", "done: B")
    end

    it "yields :task_failed events when on_error: :skip" do
      failing = Class.new(Phronomy::Agent::Base) do
        define_method(:invoke) { |_input, config: {}| raise "fail" }
      end
      klass = Class.new(described_class) { pool size: 1, agent: failing, on_error: :skip }
      team = klass.new
      seed_tasks(team, ["X"])

      events = []
      team.stream("run") { |e| events << e }

      expect(events.size).to eq(1)
      expect(events.first[:type]).to eq(:task_failed)
      expect(events.first[:error].message).to eq("fail")
    end

    it "returns the aggregated result" do
      worker_class = stub_worker { "ok" }
      klass = Class.new(described_class) do
        pool size: 1, agent: worker_class
        aggregate { |a| {count: a.size} }
      end
      team = klass.new
      seed_tasks(team, ["A", "B"])

      result = team.stream("run") { |_| }
      expect(result).to eq({count: 2})
    end

    it "falls back to #invoke behaviour when no block is given" do
      worker_class = stub_worker { "ok" }
      klass = Class.new(described_class) do
        pool size: 1, agent: worker_class
        aggregate { |a| {count: a.size} }
      end
      team = klass.new
      seed_tasks(team, ["A"])

      result = team.stream("run")  # no block
      expect(result).to eq({count: 1})
    end
  end

  # ---------------------------------------------------------------------------
  # Default scheduler
  # ---------------------------------------------------------------------------

  describe "default scheduler" do
    it "assigns tasks to the worker with the fewest accumulated messages" do
      # With 2 workers and 4 tasks using the stub_worker (adds 2 msgs per task):
      # T1 → W0 (both idle, size=0, min_by → index 0)
      # T2 → W1 (W0=2 msgs, W1=0 msgs → W1)
      # T3 → W0 (W0=2, W1=2 → tie → min_by returns first → W0)
      # T4 → W1 (W0=4, W1=2 → W1)
      worker_class = stub_worker { |input, _| "done:#{input}" }
      klass = Class.new(described_class) { pool size: 2, agent: worker_class }
      team = klass.new
      seed_tasks(team, ["T1", "T2", "T3", "T4"])

      assignments = team.invoke("run")
      task_worker_map = assignments.each_with_object({}) { |a, h| h[a[:task][:description]] = a[:worker] }

      expect(task_worker_map["T1"]).to eq(0)
      expect(task_worker_map["T2"]).to eq(1)
      expect(task_worker_map["T3"]).to eq(0)
      expect(task_worker_map["T4"]).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Custom scheduler
  # ---------------------------------------------------------------------------

  describe ".schedule (custom scheduler)" do
    it "uses the provided block to select a worker" do
      # Always pick the worker with the highest index
      worker_class = stub_worker { "ok" }
      klass = Class.new(described_class) do
        pool size: 2, agent: worker_class
        schedule { |workers| workers.max_by(&:index) }
      end
      team = klass.new
      seed_tasks(team, ["T1", "T2"])

      assignments = team.invoke("run")
      expect(assignments.map { |a| a[:worker] }).to all(eq(1))
    end
  end

  # ---------------------------------------------------------------------------
  # Built-in coordinator tools
  # ---------------------------------------------------------------------------

  describe "coordinator built-in tools" do
    describe "enqueue_task tool" do
      it "appends a task Hash to the queue and returns a confirmation string" do
        task_queue = []
        klass = described_class.new
        enqueue_tool = klass.send(:build_enqueue_tool, task_queue).new

        result = enqueue_tool.execute(description: "Migrate auth-service")

        expect(task_queue.size).to eq(1)
        expect(task_queue.first[:description]).to eq("Migrate auth-service")
        expect(task_queue.first[:id]).to eq(1)
        expect(result).to include("Task #1 enqueued")
      end

      it "increments the task id for each enqueued task" do
        task_queue = []
        klass = described_class.new
        enqueue_tool = klass.send(:build_enqueue_tool, task_queue).new

        enqueue_tool.execute(description: "Task A")
        enqueue_tool.execute(description: "Task B")

        expect(task_queue.map { |t| t[:id] }).to eq([1, 2])
      end

      it "stores optional metadata when provided" do
        task_queue = []
        klass = described_class.new
        enqueue_tool = klass.send(:build_enqueue_tool, task_queue).new

        enqueue_tool.execute(description: "Task", metadata: "high-priority")
        expect(task_queue.first[:metadata]).to eq("high-priority")
      end
    end

    describe "finalize tool" do
      it "returns a confirmation message with the current queue size" do
        task_queue = [{id: 1}, {id: 2}]
        klass = described_class.new
        finalize_tool = klass.send(:build_finalize_tool, task_queue).new

        result = finalize_tool.execute
        expect(result).to include("2 task(s) enqueued")
      end

      it "includes the optional summary in the return value" do
        task_queue = [{id: 1}]
        klass = described_class.new
        finalize_tool = klass.send(:build_finalize_tool, task_queue).new

        result = finalize_tool.execute(summary: "One auth migration queued.")
        expect(result).to include("One auth migration queued.")
      end
    end
  end
end
