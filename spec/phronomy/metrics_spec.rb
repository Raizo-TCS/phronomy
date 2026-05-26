# frozen_string_literal: true

# Task-centric observability metrics (Issue #276, extended in #307).
RSpec.describe Phronomy::Metrics do
  describe ".snapshot" do
    subject(:snap) { described_class.snapshot }

    it "returns a Hash" do
      expect(snap).to be_a(Hash)
    end

    it "includes all expected metric keys" do
      expected_keys = %i[
        blocking_pool_active
        blocking_pool_queue_length
        blocking_pool_abandoned_total
        blocking_pool_size
        event_loop_lag_last_ms
        event_loop_lag_max_ms
        event_loop_lag_average_ms
      ]
      expect(snap.keys).to include(*expected_keys)
    end

    it "includes task-centric metric keys" do
      task_keys = %i[
        active_agent_tasks
        active_tool_tasks
        active_workflow_tasks
        active_rag_tasks
        active_llm_tasks
        task_wait_time_p50_ms
        task_wait_time_p95_ms
        task_run_time_p50_ms
        task_run_time_p95_ms
        cancelled_tasks
        failed_tasks
        non_yield_threshold_violation_count
      ]
      expect(snap.keys).to include(*task_keys)
    end

    it "reports non-negative numeric values for all metrics" do
      snap.each_value do |v|
        expect(v).to be_a(Numeric)
        expect(v).to be >= 0
      end
    end

    it "reports blocking_pool_size equal to the Runtime pool's pool_size" do
      pool = Phronomy::Runtime.instance.blocking_io
      expect(snap[:blocking_pool_size]).to eq(pool.pool_size)
    end

    it "reports event_loop_lag_max_ms >= event_loop_lag_last_ms" do
      expect(snap[:event_loop_lag_max_ms]).to be >= snap[:event_loop_lag_last_ms]
    end

    it "does not raise when called multiple times" do
      3.times { expect { described_class.snapshot }.not_to raise_error }
    end

    it "active_agent_tasks reflects running agent-prefixed tasks" do
      runtime = Phronomy::Runtime.new
      barrier = Mutex.new
      cond = ConditionVariable.new
      running = false

      t = runtime.spawn(name: "agent-test-307") do
        barrier.synchronize {
          running = true
          cond.broadcast
        }
        sleep 0.2
      end

      barrier.synchronize { cond.wait(barrier, 1) until running }
      snap = runtime.task_snapshot
      expect(snap[:active_agent_tasks]).to be >= 1
      t.join
    end

    it "task_wait_time_p95_ms is populated after a burst of tasks" do
      runtime = Phronomy::Runtime.new
      tasks = 10.times.map do |i|
        runtime.spawn(name: "agent-burst-#{i}") { :done }
      end
      tasks.each(&:join)
      snap = runtime.task_snapshot
      expect(snap[:task_wait_time_p95_ms]).to be >= 0
      expect(snap[:task_run_time_p95_ms]).to be >= 0
    end
  end
end
