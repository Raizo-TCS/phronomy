# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Orchestrator do
  # Stub agent that returns a fixed output string without calling a real LLM.
  def stub_agent(output_text)
    Class.new(Phronomy::Agent::Base) do
      define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
        {output: output_text, messages: []}
      end
    end
  end

  # Stub agent that captures what it was invoked with.
  def capturing_agent
    received = []
    agent_class = Class.new(Phronomy::Agent::Base) do
      define_method(:_invoke_impl) do |input, config: {}, thread_id: nil, **|
        received << input
        {output: "echo:#{input}", messages: []}
      end
    end
    [agent_class, received]
  end

  describe "inheritance" do
    it "is a subclass of Phronomy::Agent::Base" do
      expect(described_class.ancestors).to include(Phronomy::Agent::Base)
    end
  end

  describe "#dispatch_parallel" do
    let(:orchestrator_class) do
      Class.new(described_class)
    end

    subject(:orchestrator) { orchestrator_class.new }

    it "returns results in the same order as the input tasks" do
      agent_a = stub_agent("result_a")
      agent_b = stub_agent("result_b")
      agent_c = stub_agent("result_c")

      results = orchestrator.dispatch_parallel(
        {agent: agent_a, input: "task a"},
        {agent: agent_b, input: "task b"},
        {agent: agent_c, input: "task c"}
      )

      expect(results.map { |r| r[:output] }).to eq(["result_a", "result_b", "result_c"])
    end

    it "forwards the :config hash to agent#invoke" do
      configs_received = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |input, config: {}, thread_id: nil, **|
          configs_received << config
          {output: "ok", messages: []}
        end
      end

      orchestrator.dispatch_parallel(
        {agent: agent_class, input: "task", config: {thread_id: "t1"}}
      )

      expect(configs_received.first).to eq({thread_id: "t1"})
    end

    it "uses an empty config hash when :config is omitted" do
      configs_received = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |input, config: {}, thread_id: nil, **|
          configs_received << config
          {output: "ok", messages: []}
        end
      end

      orchestrator.dispatch_parallel({agent: agent_class, input: "task"})

      expect(configs_received.first).to eq({})
    end

    it "re-raises exceptions from subagents" do
      failing_agent = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          raise "subagent exploded"
        end
      end

      expect {
        orchestrator.dispatch_parallel({agent: failing_agent, input: "test"})
      }.to raise_error(RuntimeError, "subagent exploded")
    end

    # Regression tests for Issue #99: max_concurrency and on_error
    describe "argument validation (Issue #99)" do
      it "raises ArgumentError for unknown on_error value" do
        expect {
          orchestrator.dispatch_parallel({agent: stub_agent("x"), input: "t"}, on_error: :ignore)
        }.to raise_error(ArgumentError, /unknown on_error/)
      end

      it "raises ArgumentError when max_concurrency is zero" do
        expect {
          orchestrator.dispatch_parallel({agent: stub_agent("x"), input: "t"}, max_concurrency: 0)
        }.to raise_error(ArgumentError, /max_concurrency must be a positive Integer/)
      end

      it "raises ArgumentError when max_concurrency is negative" do
        expect {
          orchestrator.dispatch_parallel({agent: stub_agent("x"), input: "t"}, max_concurrency: -1)
        }.to raise_error(ArgumentError, /max_concurrency must be a positive Integer/)
      end

      it "raises ArgumentError when max_concurrency is a string" do
        expect {
          orchestrator.dispatch_parallel({agent: stub_agent("x"), input: "t"}, max_concurrency: "2")
        }.to raise_error(ArgumentError, /max_concurrency must be a positive Integer/)
      end

      it "raises ArgumentError when max_concurrency is a float" do
        expect {
          orchestrator.dispatch_parallel({agent: stub_agent("x"), input: "t"}, max_concurrency: 1.5)
        }.to raise_error(ArgumentError, /max_concurrency must be a positive Integer/)
      end

      it "raises ArgumentError when max_concurrency is true" do
        expect {
          orchestrator.dispatch_parallel({agent: stub_agent("x"), input: "t"}, max_concurrency: true)
        }.to raise_error(ArgumentError, /max_concurrency must be a positive Integer/)
      end
    end

    describe "on_error: :skip (Issue #99)" do
      it "returns nil for failed tasks instead of raising" do
        good = stub_agent("ok")
        bad = Class.new(Phronomy::Agent::Base) do
          define_method(:_invoke_impl) { |*| raise "boom" }
        end

        results = orchestrator.dispatch_parallel(
          {agent: good, input: "a"},
          {agent: bad, input: "b"},
          {agent: good, input: "c"},
          on_error: :skip
        )

        expect(results[0][:output]).to eq("ok")
        expect(results[1]).to be_nil
        expect(results[2][:output]).to eq("ok")
      end
    end

    describe "on_error: :raise semantics (Issue #99)" do
      it "runs all tasks before re-raising (fail-last, not fail-fast)" do
        mutex = Mutex.new
        counter = 0

        counting_agent = Class.new(Phronomy::Agent::Base) do
          define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
            mutex.synchronize { counter += 1 }
            {output: "counted", messages: []}
          end
        end
        failing_agent = Class.new(Phronomy::Agent::Base) do
          define_method(:_invoke_impl) { |*| raise "task failed" }
        end

        expect {
          orchestrator.dispatch_parallel(
            {agent: counting_agent, input: "1"},
            {agent: failing_agent, input: "2"},
            {agent: counting_agent, input: "3"},
            on_error: :raise
          )
        }.to raise_error(RuntimeError, "task failed")

        # Both counting tasks must have run despite the failure in task 2
        expect(counter).to eq(2)
      end

      it "re-raises the first error in input order, not the fastest failure" do
        # Task 0 and task 2 both fail; task 0 is first in input order
        error_0 = RuntimeError.new("error from task 0")
        error_2 = RuntimeError.new("error from task 2")

        failing_first = Class.new(Phronomy::Agent::Base) do
          error_0_ref = error_0
          define_method(:_invoke_impl) { |*| raise error_0_ref }
        end
        failing_third = Class.new(Phronomy::Agent::Base) do
          error_2_ref = error_2
          define_method(:_invoke_impl) { |*| raise error_2_ref }
        end
        good = stub_agent("ok")

        expect {
          orchestrator.dispatch_parallel(
            {agent: failing_first, input: "0"},
            {agent: good, input: "1"},
            {agent: failing_third, input: "2"},
            on_error: :raise
          )
        }.to raise_error(error_0)
      end
    end

    describe "max_concurrency (Issue #99)" do
      it "returns correct results when max_concurrency: 1 (serial execution)" do
        agent_a = stub_agent("a")
        agent_b = stub_agent("b")
        agent_c = stub_agent("c")

        results = orchestrator.dispatch_parallel(
          {agent: agent_a, input: "x"},
          {agent: agent_b, input: "y"},
          {agent: agent_c, input: "z"},
          max_concurrency: 1
        )

        expect(results.map { |r| r[:output] }).to eq(%w[a b c])
      end

      it "returns correct results when max_concurrency exceeds task count" do
        agents = 3.times.map { |i| stub_agent("r#{i}") }
        tasks = agents.each_with_index.map { |a, i| {agent: a, input: i.to_s} }

        results = orchestrator.dispatch_parallel(*tasks, max_concurrency: 10)

        expect(results.map { |r| r[:output] }).to eq(%w[r0 r1 r2])
      end

      it "returns [] for empty task list" do
        expect(orchestrator.dispatch_parallel).to eq([])
      end
    end
  end

  describe "#fan_out" do
    let(:orchestrator_class) { Class.new(described_class) }
    subject(:orchestrator) { orchestrator_class.new }

    it "runs the same agent against every input and returns results in order" do
      agent_class, received = capturing_agent

      results = orchestrator.fan_out(agent: agent_class, inputs: %w[a b c])

      expect(received.sort).to eq(%w[a b c])
      expect(results.map { |r| r[:output] }.sort).to eq(%w[echo:a echo:b echo:c])
    end

    it "forwards config to every agent invocation" do
      configs_received = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          configs_received << config
          {output: "ok", messages: []}
        end
      end

      orchestrator.fan_out(agent: agent_class, inputs: %w[x y], config: {thread_id: "t2"})

      expect(configs_received).to all(eq({thread_id: "t2"}))
    end

    it "forwards max_concurrency: to dispatch_parallel (Issue #99)" do
      results = orchestrator.fan_out(
        agent: stub_agent("ok"),
        inputs: %w[a b c],
        max_concurrency: 1
      )
      expect(results.map { |r| r[:output] }).to eq(%w[ok ok ok])
    end

    it "forwards on_error: :skip to dispatch_parallel (Issue #99)" do
      bad = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) { |*| raise "oops" }
      end

      results = orchestrator.fan_out(
        agent: bad,
        inputs: %w[a b],
        on_error: :skip
      )
      expect(results).to eq([nil, nil])
    end
  end

  describe ".subagent DSL" do
    let(:orchestrator_class) do
      agent_a = stub_agent("from_a")
      agent_b = stub_agent("from_b")

      Class.new(described_class) do
        subagent :researcher, agent_a
        subagent :analyst, agent_b
      end
    end

    it "registers both subagents in the class registry" do
      expect(orchestrator_class.registered_subagents.keys).to contain_exactly(:researcher, :analyst)
    end

    it "adds a tool for each declared subagent" do
      expect(orchestrator_class.tools.length).to eq(2)
    end

    it "names each tool dispatch_to_<name>" do
      tool_names = orchestrator_class.tools.map(&:tool_name)
      expect(tool_names).to contain_exactly("dispatch_to_researcher", "dispatch_to_analyst")
    end

    it "each generated tool executes the corresponding subagent" do
      tool_class = orchestrator_class.tools.find { |t| t.tool_name == "dispatch_to_researcher" }
      result = tool_class.new.execute(input: "what happened?")
      expect(result).to eq("from_a")
    end

    it "does not share the tool list with a sibling subclass" do
      sibling = Class.new(described_class) do
        subagent :helper, Class.new(Phronomy::Agent::Base) {
          define_method(:_invoke_impl) { |*| {output: "help", messages: []} }
        }
      end

      # sibling has 1 tool; orchestrator_class has 2 tools — they must not bleed
      expect(sibling.tools.length).to eq(1)
      expect(orchestrator_class.tools.length).to eq(2)
    end
  end

  describe ".subagent on_error:" do
    context "when :raise (default)" do
      let(:orchestrator_class) do
        failing = Class.new(Phronomy::Agent::Base) do
          define_method(:_invoke_impl) { |*| raise "boom" }
        end

        Class.new(described_class) do
          subagent :failing_worker, failing
        end
      end

      it "re-raises the exception from the generated tool" do
        tool_class = orchestrator_class.tools.first
        expect { tool_class.new.execute(input: "go") }.to raise_error(RuntimeError, "boom")
      end
    end

    context "when :skip" do
      let(:orchestrator_class) do
        failing = Class.new(Phronomy::Agent::Base) do
          define_method(:_invoke_impl) { |*| raise "boom" }
        end

        Class.new(described_class) do
          subagent :failing_worker, failing, on_error: :skip
        end
      end

      it "returns nil from the generated tool instead of raising" do
        tool_class = orchestrator_class.tools.first
        expect(tool_class.new.execute(input: "go")).to be_nil
      end
    end
  end

  describe ".registered_subagents" do
    it "is isolated per subclass (not shared via inheritance)" do
      base_class = Class.new(described_class) do
        subagent :base_worker, Class.new(Phronomy::Agent::Base) {
          define_method(:_invoke_impl) { |*| {output: "base", messages: []} }
        }
      end

      child_class = Class.new(base_class)

      expect(base_class.registered_subagents.keys).to include(:base_worker)
      expect(child_class.registered_subagents).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # config and thread_id propagation (issue #132)
  # ---------------------------------------------------------------------------

  describe "config and thread_id propagation (issue #132)" do
    let(:orchestrator_class) { Class.new(described_class) }
    subject(:orchestrator) { orchestrator_class.new }

    it "#dispatch_parallel forwards thread_id to every sub-agent invocation" do
      received_thread_ids = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          received_thread_ids << thread_id
          {output: "ok", messages: []}
        end
      end

      orchestrator.dispatch_parallel(
        {agent: agent_class, input: "a", thread_id: "t-abc"},
        {agent: agent_class, input: "b", thread_id: "t-abc"}
      )

      expect(received_thread_ids).to all(eq("t-abc"))
    end

    it "#fan_out forwards thread_id to every sub-agent invocation" do
      received_thread_ids = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          received_thread_ids << thread_id
          {output: "ok", messages: []}
        end
      end

      orchestrator.fan_out(agent: agent_class, inputs: %w[x y z], thread_id: "t-xyz")

      expect(received_thread_ids).to all(eq("t-xyz"))
    end

    it "#subagent instance method inherits thread_id from parent invoke context" do
      received_thread_ids = []
      sub_agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          received_thread_ids << thread_id
          {output: "sub", messages: []}
        end
      end

      sub_agent_ref = sub_agent_class

      orch_class = Class.new(described_class) do
        model "test-model"

        define_method(:invoke_once) do |input, messages: [], thread_id: nil, config: {}|
          subagent(sub_agent_ref, input, thread_id: thread_id, config: config)
          {output: "done", messages: []}
        end
      end

      # Call invoke_once directly (bypasses LLM stub requirements)
      orch = orch_class.new
      orch.send(:invoke_once, "hello", thread_id: "parent-thread")

      expect(received_thread_ids).to eq(["parent-thread"])
    end
  end

  describe "#dispatch_parallel timeout: option (Issue #133)" do
    let(:orchestrator_class) { Class.new(described_class) }
    subject(:orchestrator) { orchestrator_class.new }

    it "raises Phronomy::TimeoutError when a worker exceeds the timeout" do
      slow_agent = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          sleep(10)
          {output: "never", messages: []}
        end
      end

      expect {
        orchestrator.dispatch_parallel(
          {agent: slow_agent, input: "x"},
          timeout: 0.1
        )
      }.to raise_error(Phronomy::TimeoutError, /timed out/)
    end

    it "does not raise when all workers finish within the timeout" do
      fast_agent = stub_agent("fast")

      expect {
        orchestrator.dispatch_parallel(
          {agent: fast_agent, input: "x"},
          timeout: 5
        )
      }.not_to raise_error
    end
  end

  describe "#dispatch_parallel force_kill: option (Issue #235)" do
    let(:orchestrator_class) { Class.new(described_class) }
    subject(:orchestrator) { orchestrator_class.new }

    let(:slow_agent_class) do
      Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, **|
          sleep(10)
          {output: "never", messages: []}
        end
      end
    end

    it "raises TimeoutError with force_kill: false (default) and does not kill the worker" do
      expect {
        orchestrator.dispatch_parallel(
          {agent: slow_agent_class, input: "x"},
          timeout: 0.05,
          force_kill: false
        )
      }.to raise_error(Phronomy::TimeoutError)
    end

    it "raises TimeoutError with force_kill: true and calls Thread#kill on still-running workers" do
      expect {
        orchestrator.dispatch_parallel(
          {agent: slow_agent_class, input: "x"},
          timeout: 0.05,
          force_kill: true
        )
      }.to raise_error(Phronomy::TimeoutError)
    end

    it "defaults to force_kill: false (TimeoutError raised without force_kill: keyword)" do
      # Verify the default is force_kill: false by omitting the keyword entirely.
      expect {
        orchestrator.dispatch_parallel({agent: slow_agent_class, input: "x"}, timeout: 0.05)
      }.to raise_error(Phronomy::TimeoutError)
    end

    it "fan_out: propagates force_kill: false through to bounded_map" do
      expect {
        orchestrator.fan_out(
          agent: slow_agent_class,
          inputs: ["x"],
          timeout: 0.05,
          force_kill: false
        )
      }.to raise_error(Phronomy::TimeoutError)
    end
  end
end
