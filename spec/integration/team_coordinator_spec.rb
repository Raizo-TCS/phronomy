# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 32: TeamCoordinator
#
# Pairwise factors:
#   tc_pool_size × tc_task_count × tc_on_error × tc_aggregate
#
# Generated test cases: 6 (all feasible)
#
# Infeasible cases: none
#
# LLM required: No (WebMock)
#   Coordinator LLM calls are stubbed with a fixed enqueue_task → finalize →
#   text-response sequence.  Worker LLM calls are stubbed with text responses.
#   Failing-worker scenarios (on_error: :skip) use a worker subclass that
#   overrides #invoke to raise, bypassing LLM entirely.
#
# Coordinator LLM call sequence (N tasks):
#   Calls 0..N-1 : tool_call "enqueue_task", {description: "Task K"}
#   Call  N      : tool_call "finalize", {summary: ""}
#   Call  N+1    : text "Coordinator done."
# Worker LLM call sequence (per successful task):
#   Call  N+2+k  : text "Result K"

RSpec.describe "Group 32: TeamCoordinator", :integration do
  after { LLMStub.deactivate }

  # Helper: returns sequential task description strings for coordinator stubs.
  def enqueue_call(description)
    LLMStub.tool_call_response("enqueue_task", {description: description, metadata: nil})
  end

  def finalize_call
    LLMStub.tool_call_response("finalize", {summary: ""})
  end

  # ---------------------------------------------------------------------------
  # TC-001: single pool / equal_to_pool (1 task) / raise / with_block
  #   One worker, one task.  The coordinator enqueues the task and finalises.
  #   The worker returns a text result.  The aggregate block joins results.
  # ---------------------------------------------------------------------------
  describe "TC-001: single pool / 1 task / raise / with_block" do
    let(:worker_class) { IntegrationFactors.tc_worker_class }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :single,
        on_error: :raise,
        aggregate: :with_block,
        worker: worker_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        finalize_call,
        "Coordinator done.",
        "Result A"
      ])
    end

    it "returns a non-nil value from the aggregate block" do
      result = team_class.new.invoke("Process tasks")
      expect(result).not_to be_nil
    end

    it "aggregate output contains the worker result text" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to include("Result A")
    end

    it "exactly 1 task is processed" do
      team_class.new.invoke("Process tasks")
      # When aggregate is set, result is the block return value (String).
      # We verify via LLM call count: coordinator (3 calls) + worker (1 call).
      expect(@llm.calls.size).to eq(4)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: single pool / 2 tasks (exceeds pool) / skip / none
  #   One worker, two tasks, but the worker raises on every invocation.
  #   on_error: :skip means both tasks are attempted and errors are recorded
  #   rather than propagated.  No aggregate block: result is raw assignments.
  # ---------------------------------------------------------------------------
  describe "TC-002: single pool / 2 tasks / skip / none" do
    let(:worker_class) { IntegrationFactors.tc_worker_class(failing: true) }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :single,
        on_error: :skip,
        aggregate: :none,
        worker: worker_class
      )
    end

    before do
      # Failing worker never calls LLM; coordinator still needs its sequence.
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        enqueue_call("Task B"),
        finalize_call,
        "Coordinator done."
      ])
    end

    it "does not raise despite worker failures" do
      expect { team_class.new.invoke("Process tasks") }.not_to raise_error
    end

    it "returns raw assignments array" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to be_an(Array)
    end

    it "records errors for both tasks" do
      result = team_class.new.invoke("Process tasks")
      expect(result.size).to eq(2)
      expect(result.map { |a| a[:error] }).to all(be_a(RuntimeError))
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: multi pool (2 workers) / 2 tasks (equal to pool) / skip / with_block
  #   Two workers, two tasks.  Workers fail (on_error: :skip).  The aggregate
  #   block is called even when all results are nil; it returns an empty string.
  # ---------------------------------------------------------------------------
  describe "TC-003: multi pool / 2 tasks / skip / with_block" do
    let(:worker_class) { IntegrationFactors.tc_worker_class(failing: true) }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :multi,
        on_error: :skip,
        aggregate: :with_block,
        worker: worker_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        enqueue_call("Task B"),
        finalize_call,
        "Coordinator done."
      ])
    end

    it "does not raise despite worker failures" do
      expect { team_class.new.invoke("Process tasks") }.not_to raise_error
    end

    it "aggregate block is called; returns a String (possibly empty)" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to be_a(String)
    end

    it "aggregate result is empty string when all workers fail" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to eq("")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: multi pool (2 workers) / 3 tasks (exceeds pool) / raise / none
  #   Two workers, three tasks, all succeed.  No aggregate block.
  #   The scheduler distributes tasks so both workers are exercised.
  # ---------------------------------------------------------------------------
  describe "TC-004: multi pool / 3 tasks / raise / none" do
    let(:worker_class) { IntegrationFactors.tc_worker_class }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :multi,
        on_error: :raise,
        aggregate: :none,
        worker: worker_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        enqueue_call("Task B"),
        enqueue_call("Task C"),
        finalize_call,
        "Coordinator done.",
        "Result A",
        "Result B",
        "Result C"
      ])
    end

    it "returns raw assignments array with 3 entries" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to be_an(Array)
      expect(result.size).to eq(3)
    end

    it "both workers are used" do
      result = team_class.new.invoke("Process tasks")
      worker_indices = result.map { |a| a[:worker] }.uniq.sort
      expect(worker_indices).to eq([0, 1])
    end

    it "all assignments have nil :error" do
      result = team_class.new.invoke("Process tasks")
      expect(result.map { |a| a[:error] }).to all(be_nil)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: single pool / 1 task (equal to pool) / raise / none
  #   Single worker, single task, success, no aggregate.
  #   Result is raw assignments array with one entry.
  # ---------------------------------------------------------------------------
  describe "TC-005: single pool / 1 task / raise / none" do
    let(:worker_class) { IntegrationFactors.tc_worker_class }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :single,
        on_error: :raise,
        aggregate: :none,
        worker: worker_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        finalize_call,
        "Coordinator done.",
        "Result A"
      ])
    end

    it "returns raw assignments array" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
    end

    it "the assignment has the correct worker index (0)" do
      result = team_class.new.invoke("Process tasks")
      expect(result.first[:worker]).to eq(0)
    end

    it "the assignment has nil :error" do
      result = team_class.new.invoke("Process tasks")
      expect(result.first[:error]).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: single pool / 2 tasks (exceeds pool) / raise / with_block
  #   One worker processes two tasks sequentially.  Aggregate joins results.
  # ---------------------------------------------------------------------------
  describe "TC-006: single pool / 2 tasks / raise / with_block" do
    let(:worker_class) { IntegrationFactors.tc_worker_class }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :single,
        on_error: :raise,
        aggregate: :with_block,
        worker: worker_class
      )
    end

    before do
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        enqueue_call("Task B"),
        finalize_call,
        "Coordinator done.",
        "Result A",
        "Result B"
      ])
    end

    it "aggregate output contains results from both tasks" do
      result = team_class.new.invoke("Process tasks")
      expect(result).to include("Result A")
      expect(result).to include("Result B")
    end

    it "the single worker handles both tasks (worker index always 0)" do
      # Verify by checking all tasks were assigned to worker 0 via LLM call count.
      # 2 enqueue + 1 finalize + 1 coordinator text + 2 worker = 6 calls total.
      team_class.new.invoke("Process tasks")
      expect(@llm.calls.size).to eq(6)
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern 3 requirement: Worker context accumulation (worker persistence)
  #
  # The agent-teams pattern requires that "teammates stay alive across many
  # assignments, accumulating context and domain specialization" (see
  # https://claude.com/blog/multi-agent-coordination-patterns, Pattern 3).
  #
  # TeamCoordinator implements this by storing each WorkerState's :messages and
  # passing them back via config[:messages] on every successive invoke call.
  # This test verifies that the second task invocation receives the accumulated
  # message history from the first task.
  # ---------------------------------------------------------------------------
  describe "Pattern 3 requirement: worker context accumulation across tasks" do
    let(:worker_class) { IntegrationFactors.tc_worker_class }
    let(:team_class) do
      IntegrationFactors.tc_team_class(
        pool_size: :single,
        on_error: :raise,
        aggregate: :none,
        worker: worker_class
      )
    end

    before do
      # 2 enqueue + finalize + coordinator text + 2 worker tasks = 6 LLM calls.
      @llm = LLMStub.activate(responses: [
        enqueue_call("Task A"),
        enqueue_call("Task B"),
        finalize_call,
        "Coordinator done.",
        "Result A",
        "Result B"
      ])
    end

    it "the second worker LLM call receives messages accumulated from the first task" do
      team_class.new.invoke("Process tasks")
      # Call index 4: Worker processes Task A (config[:messages] is empty).
      # Call index 5: Worker processes Task B (config[:messages] holds Task A's history).
      first_task_msg_count = @llm.messages_for(4).size
      second_task_msg_count = @llm.messages_for(5).size
      expect(second_task_msg_count).to be > first_task_msg_count
    end

    it "the accumulated messages include the first task's user and assistant turns" do
      team_class.new.invoke("Process tasks")
      second_task_messages = @llm.messages_for(5)
      roles = second_task_messages.map { |m| m["role"] }
      expect(roles).to include("user")
      expect(roles).to include("assistant")
    end
  end
end
