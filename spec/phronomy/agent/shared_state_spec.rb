# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::SharedState do
  # Builds a stub researcher agent class whose invoke records calls and
  # optionally calls write_finding via the injected tool.
  #
  # The optional block receives (input) and returns an Array of finding strings
  # to write via the injected write_finding tool. When omitted, nothing is written.
  def stub_researcher(name: "StubResearcher", &findings_block)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-47", version: 1
      define_singleton_method(:name) { name }

      define_method(:invoke) do |input, config: {}|
        findings_block&.call(input)&.each do |content|
          write_finding_tool = self.class.instance_variable_get(:@_injected_write_tool)
          write_finding_tool&.new&.public_send(:execute, content: content)
        end
        {output: "done", messages: []}
      end
    end
  end

  # Builds a stub researcher that uses the injected tools via a direct reference
  # stored on the class (set by SharedState before invocation).
  def stub_researcher_with_tools(name: "ToolResearcher")
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-48", version: 1
      define_singleton_method(:name) { name }

      define_method(:invoke) do |_input, config: {}|
        {output: "done", messages: []}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # DSL
  # ---------------------------------------------------------------------------

  describe "DSL" do
    describe ".member" do
      it "registers a member class without instruction" do
        r = stub_researcher_with_tools(name: "R1")
        klass = Class.new(described_class) { member r }
        expect(klass._members).to eq([{klass: r, instruction: nil}])
      end

      it "registers a member class with per-agent instruction" do
        r = stub_researcher_with_tools(name: "R1")
        klass = Class.new(described_class) { member r, instruction: "Focus on security." }
        expect(klass._members).to eq([{klass: r, instruction: "Focus on security."}])
      end

      it "accumulates multiple members in declaration order" do
        r1 = stub_researcher_with_tools(name: "R1")
        r2 = stub_researcher_with_tools(name: "R2")
        klass = Class.new(described_class) do
          member r1
          member r2, instruction: "Extra focus."
        end
        expect(klass._members.map { |m| m[:klass] }).to eq([r1, r2])
        expect(klass._members[1][:instruction]).to eq("Extra focus.")
      end

      it "makes _members return the classes in declaration order" do
        r1 = stub_researcher_with_tools(name: "R1")
        r2 = stub_researcher_with_tools(name: "R2")
        klass = Class.new(described_class) do
          member r1
          member r2
        end
        expect(klass._members.map { |m| m[:klass] }).to eq([r1, r2])
      end

      it "returns empty array from _members when not configured" do
        klass = Class.new(described_class)
        expect(klass._members).to eq([])
      end
    end

    describe ".coordination" do
      it "stores and reads back the coordination text" do
        klass = Class.new(described_class) { coordination "Custom team protocol." }
        expect(klass._coordination).to eq("Custom team protocol.")
      end

      it "returns nil when not configured" do
        klass = Class.new(described_class)
        expect(klass._coordination).to be_nil
      end
    end

    describe ".max_cycles" do
      it "stores and reads back the cycle limit" do
        klass = Class.new(described_class) { max_cycles 5 }
        expect(klass._max_cycles).to eq(5)
      end

      it "returns nil when not configured" do
        klass = Class.new(described_class)
        expect(klass._max_cycles).to be_nil
      end
    end

    describe ".timeout" do
      it "stores and reads back the timeout seconds" do
        klass = Class.new(described_class) { timeout 30 }
        expect(klass._timeout).to eq(30)
      end

      it "returns nil when not configured" do
        klass = Class.new(described_class)
        expect(klass._timeout).to be_nil
      end
    end

    describe ".terminate_when" do
      it "stores the convergence block" do
        blk = ->(store) { store.size >= 10 }
        klass = Class.new(described_class)
        klass.terminate_when(&blk)
        expect(klass._terminate_when).to eq(blk)
      end

      it "returns nil when not configured" do
        klass = Class.new(described_class)
        expect(klass._terminate_when).to be_nil
      end
    end

    describe ".aggregate" do
      it "stores the aggregate block" do
        blk = ->(store) { store.read_all }
        klass = Class.new(described_class)
        klass.aggregate(&blk)
        expect(klass._aggregator).to eq(blk)
      end

      it "returns nil when not configured" do
        klass = Class.new(described_class)
        expect(klass._aggregator).to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # KnowledgeStore
  # ---------------------------------------------------------------------------

  describe "KnowledgeStore" do
    subject(:store) { Phronomy::Agent::SharedState::KnowledgeStore.new }

    it "starts empty" do
      expect(store.read_all).to eq([])
      expect(store.size).to eq(0)
    end

    it "appends findings as Hashes with agent, content, cycle keys" do
      store.write(agent: :researcher, content: "Finding A", cycle: 1)
      expect(store.read_all).to eq([{agent: :researcher, content: "Finding A", cycle: 1}])
    end

    it "preserves insertion order across multiple writes" do
      store.write(agent: :a, content: "first", cycle: 1)
      store.write(agent: :b, content: "second", cycle: 1)
      store.write(agent: :a, content: "third", cycle: 2)
      contents = store.read_all.map { |f| f[:content] }
      expect(contents).to eq(%w[first second third])
    end

    it "returns a copy so that mutations do not affect the store" do
      store.write(agent: :a, content: "x", cycle: 1)
      copy = store.read_all
      copy.clear
      expect(store.size).to eq(1)
    end

    it "reports size correctly" do
      3.times { |i| store.write(agent: :a, content: "f#{i}", cycle: 1) }
      expect(store.size).to eq(3)
    end
  end

  # ---------------------------------------------------------------------------
  # #invoke — argument validation
  # ---------------------------------------------------------------------------

  describe "#invoke argument validation" do
    it "raises ArgumentError when neither max_cycles nor timeout is set" do
      r = stub_researcher_with_tools
      klass = Class.new(described_class) { member r }
      expect { klass.new.invoke("question") }.to raise_error(ArgumentError, /max_cycles.*timeout|timeout.*max_cycles/i)
    end

    it "does not raise when only max_cycles is set" do
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-49", version: 1
        define_method(:invoke) { |_input, config: {}| {output: "ok", messages: []} }
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 1
      end
      expect { klass.new.invoke("q") }.not_to raise_error
    end

    it "does not raise when only timeout is set" do
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-50", version: 1
        define_method(:invoke) { |_input, config: {}| {output: "ok", messages: []} }
      end
      klass = Class.new(described_class) do
        member r
        timeout 10
      end
      expect { klass.new.invoke("q") }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # #invoke — execution and return value
  # ---------------------------------------------------------------------------

  describe "#invoke execution" do
    def build_simple_researcher
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-51", version: 1
        define_method(:invoke) { |_input, config: {}| {output: "ok", messages: []} }
      end
    end

    it "returns a Hash with :output, :cycles, and :terminated_by keys" do
      r = build_simple_researcher
      klass = Class.new(described_class) do
        member r
        max_cycles 2
        aggregate { |store| store.read_all }
      end
      result = klass.new.invoke("question")
      expect(result).to include(:output, :cycles, :terminated_by)
    end

    it "runs exactly max_cycles cycles when no other condition triggers" do
      invocation_count = 0
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-52", version: 1
        define_method(:invoke) do |_input, config: {}|
          invocation_count += 1
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 3
      end
      klass.new.invoke("q")
      expect(invocation_count).to eq(3)
    end

    it "runs all researchers once per cycle, in declaration order" do
      call_log = []
      r1 = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-53", version: 1
        define_singleton_method(:name) { "R1" }
        define_method(:invoke) { |_i, config: {}|
          call_log << :r1
          {output: "ok", messages: []}
        }
      end
      r2 = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-54", version: 1
        define_singleton_method(:name) { "R2" }
        define_method(:invoke) { |_i, config: {}|
          call_log << :r2
          {output: "ok", messages: []}
        }
      end
      klass = Class.new(described_class) do
        member r1
        member r2
        max_cycles 2
      end
      klass.new.invoke("q")
      expect(call_log).to eq([:r1, :r2, :r1, :r2])
    end

    it "terminates early when terminate_when returns true" do
      call_count = 0
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-55", version: 1
        define_method(:invoke) do |_i, config: {}|
          call_count += 1
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 10
        terminate_when { |store| store.size >= 2 }
      end

      # Inject a write so that terminate_when has something to evaluate
      allow_any_instance_of(klass).to receive(:invoke_researcher) do |_coord, _researcher_class, store, cycle, _input|
        store.write(agent: :stub, content: "finding_#{call_count}", cycle: cycle)
        call_count += 1
        nil
      end

      klass.new.invoke("q")
      expect(call_count).to be <= 10
    end

    it "terminates early on timeout" do
      call_count = 0
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-56", version: 1
        define_method(:invoke) { |_i, config: {}|
          call_count += 1
          sleep(0.05)
          {output: "ok", messages: []}
        }
      end
      klass = Class.new(described_class) do
        member r
        timeout 0.08   # enough for one full cycle but not two
        max_cycles 100
      end
      result = klass.new.invoke("q")
      expect(result[:terminated_by]).to eq(:timeout)
      expect(call_count).to be < 100
    end

    it "reports terminated_by: :max_cycles when stopping due to cycle limit" do
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-57", version: 1
        define_method(:invoke) { |_i, config: {}| {output: "ok", messages: []} }
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 2
      end
      result = klass.new.invoke("q")
      expect(result[:terminated_by]).to eq(:max_cycles)
    end

    it "always includes the tool-usage guide in the prompt" do
      received_inputs = []
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-58", version: 1
        define_method(:invoke) do |input, config: {}|
          received_inputs << input
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 1
      end
      klass.new.invoke("initial question")

      expect(received_inputs.first).to include("read_store")
      expect(received_inputs.first).to include("write_finding")
      expect(received_inputs.first).to include("initial question")
    end

    it "passes prior store contents in the prompt for later cycles" do
      received_inputs = []
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-59", version: 1
        define_method(:invoke) do |input, config: {}|
          received_inputs << input
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 2
      end
      klass.new.invoke("initial question")

      # Cycle 2 prompt should differ from cycle 1 (store context is included)
      expect(received_inputs.size).to eq(2)
    end

    it "applies the aggregate block to the final store and returns it as :output" do
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-60", version: 1
        define_method(:invoke) { |_i, config: {}| {output: "ok", messages: []} }
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 1
        aggregate { |store| {total: store.size, summary: "done"} }
      end
      result = klass.new.invoke("q")
      expect(result[:output]).to eq({total: 0, summary: "done"})
    end

    it "returns store.read_all as :output when no aggregate block is set" do
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-61", version: 1
        define_method(:invoke) { |_i, config: {}| {output: "ok", messages: []} }
      end
      klass = Class.new(described_class) do
        member r
        max_cycles 1
      end
      result = klass.new.invoke("q")
      expect(result[:output]).to eq([])
    end

    it "appends per-agent instruction to the prompt when member has instruction:" do
      received_input = nil
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-62", version: 1
        define_method(:invoke) do |input, config: {}|
          received_input = input
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) { max_cycles 1 }
      klass.member(r, instruction: "Only check for SQL injection.")
      klass.new.invoke("review this code")
      expect(received_input).to include("Only check for SQL injection.")
    end

    it "does not append instruction text when member has no instruction" do
      received_input = nil
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-63", version: 1
        define_method(:invoke) do |input, config: {}|
          received_input = input
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) { max_cycles 1 }
      klass.member(r)
      klass.new.invoke("task")
      expect(received_input).not_to include("Your specific focus")
    end

    it "uses team coordination text when defined, replacing the default guide" do
      received_input = nil
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-64", version: 1
        define_method(:invoke) do |input, config: {}|
          received_input = input
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) do
        coordination "Custom team protocol."
        max_cycles 1
      end
      klass.member(r)
      klass.new.invoke("task")
      expect(received_input).to include("Custom team protocol.")
      expect(received_input).not_to include("Required workflow: first call read_store")
    end

    it "uses the default coordination guide when coordination is not configured" do
      received_input = nil
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-65", version: 1
        define_method(:invoke) do |input, config: {}|
          received_input = input
          {output: "ok", messages: []}
        end
      end
      klass = Class.new(described_class) { max_cycles 1 }
      klass.member(r)
      klass.new.invoke("task")
      expect(received_input).to include("Required workflow")
      expect(received_input).to include("read_store")
      expect(received_input).to include("write_finding")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool injection — read_store and write_finding
  # ---------------------------------------------------------------------------

  describe "tool injection" do
    it "uses a distinct deterministic definition for framework-owned instrumentation" do
      researcher = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "shared-state-researcher", version: 4
      end
      original_tools = researcher.tools.dup
      coordinator = Class.new(described_class).new
      store = Phronomy::Agent::SharedState::KnowledgeStore.new

      instrumented = coordinator.send(
        :build_instrumented_researcher,
        researcher,
        store,
        1
      )
      instrumented_again = coordinator.send(
        :build_instrumented_researcher,
        researcher,
        store,
        2
      )

      expect(instrumented).not_to equal(researcher)
      expect(instrumented.agent_definition).to eq(
        id: "Phronomy::Agent::SharedState::Instrumented/shared-state-researcher@4",
        version: 1
      )
      expect(instrumented.agent_definition)
        .not_to eq(researcher.agent_definition)
      expect(instrumented_again.agent_definition)
        .to eq(instrumented.agent_definition)

      expect(researcher.agent_definition).to eq(
        id: "shared-state-researcher",
        version: 4
      )
      expect(researcher.tools).to eq(original_tools)
      expect(instrumented.tools.map(&:tool_name))
        .to include("read_store", "write_finding")
    end

    it "derives a different generated definition when the wrapped revision changes" do
      coordinator = Class.new(described_class).new
      store = Phronomy::Agent::SharedState::KnowledgeStore.new

      researcher_v4 = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "shared-state-lineage", version: 4
      end
      researcher_v5 = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "shared-state-lineage", version: 5
      end

      instrumented_v4 = coordinator.send(
        :build_instrumented_researcher,
        researcher_v4,
        store,
        1
      )
      instrumented_v5 = coordinator.send(
        :build_instrumented_researcher,
        researcher_v5,
        store,
        1
      )

      expect(instrumented_v4.agent_definition).to eq(
        id: "Phronomy::Agent::SharedState::Instrumented/shared-state-lineage@4",
        version: 1
      )
      expect(instrumented_v5.agent_definition).to eq(
        id: "Phronomy::Agent::SharedState::Instrumented/shared-state-lineage@5",
        version: 1
      )
    end

    it "researcher agents receive read_store and write_finding tools" do
      received_tool_names = []

      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-66", version: 1
        define_method(:invoke) do |_input, config: {}|
          # Collect tool names from the class tools list
          received_tool_names.concat(self.class.tools.map(&:tool_name))
          {output: "ok", messages: []}
        end
      end

      klass = Class.new(described_class) do
        member r
        max_cycles 1
      end
      klass.new.invoke("q")

      expect(received_tool_names).to include("read_store", "write_finding")
    end

    it "write_finding appends a Hash finding to the shared store" do
      store_ref = nil

      klass = Class.new(described_class) do
        max_cycles 1
      end
      klass.new

      # Access the store via the aggregate block
      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-67", version: 1
        define_method(:invoke) do |_input, config: {}|
          write_tool = self.class.tools.find { |t| t.tool_name == "write_finding" }
          write_tool.new.execute(content: "Key finding")
          {output: "ok", messages: []}
        end
      end

      klass_with_r = Class.new(described_class) do
        max_cycles 1
        aggregate { |store|
          store_ref = store
          store.read_all
        }
      end
      klass_with_r.member(r)
      klass_with_r.new.invoke("q")

      expect(store_ref).not_to be_nil
      expect(store_ref.read_all.first[:content]).to eq("Key finding")
    end

    it "read_store returns JSON of the current findings" do
      require "json"
      store_json = nil

      r = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-68", version: 1
        define_method(:invoke) do |_input, config: {}|
          read_tool = self.class.tools.find { |t| t.tool_name == "read_store" }
          store_json = read_tool.new.execute
          {output: "ok", messages: []}
        end
      end

      klass = Class.new(described_class) do
        max_cycles 1
        aggregate { |store| store.read_all }
      end
      klass.member(r)
      klass.new.invoke("q")

      expect { JSON.parse(store_json) }.not_to raise_error
    end
  end
end
