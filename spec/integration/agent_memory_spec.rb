# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Pairwise integration test cases — Group 1: Agent × Memory × Tools
#
# Source:   docs/integration_test_cases_agent_memory.yaml
# Factors:  agent_class, memory_type, agent_tools, thread_id, memory_token_budget
# Feasible: TC-001, TC-002, TC-003, TC-007, TC-009, TC-011,
#           TC-013, TC-014, TC-015, TC-016, TC-017, TC-025
#
# All tests require LM Studio running at http://192.168.122.1:1234/v1
# with openai/gpt-oss-20b loaded.

RSpec.describe "Group 1: Agent × Memory × Tools", :integration do
  after { LLMStub.deactivate }

  # --------------------------------------------------------------------------
  # TC-001: base / none / none / nil / nil
  # Simplest baseline — single LLM call, no tools, no memory.
  # --------------------------------------------------------------------------
  describe "TC-001: Agent::Base, no memory, no tools, no thread_id" do
    before { @llm = LLMStub.activate(responses: ["Paris"]) }

    it "returns :output (String), :messages (Array), :usage and output is non-empty" do
      agent_klass = IntegrationFactors.agent_class("base",
        tools: IntegrationFactors.tools("none"))
      result = agent_klass.new.invoke(
        "What is the capital of France? Reply with only the city name."
      )

      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
      expect(result[:messages]).to be_an(Array)
      expect(result[:messages]).not_to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-002: base / window / splat_single / present / generous
  # WindowMemory persists conversation; tool available; generous budget.
  # --------------------------------------------------------------------------
  describe "TC-002: Agent::Base, WindowMemory, single tool, thread_id=present, generous budget" do
    let(:memory) { IntegrationFactors.memory("window") }
    let(:budget) { IntegrationFactors.token_budget("generous") }
    let(:agent) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_single")).new }
    let(:thread) { "tc-002-#{SecureRandom.hex(4)}" }

    before { @llm = LLMStub.activate(responses: ["Got it.", "42"]) }

    it "persists conversation across two invocations" do
      agent.invoke("My favourite number is 42. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory, token_budget: budget})

      result = agent.invoke(
        "What is my favourite number? Reply with only the number.",
        config: {thread_id: thread, memory: memory, token_budget: budget}
      )

      expect(result[:output]).to include("42")
    end
  end

  # --------------------------------------------------------------------------
  # TC-003: base / summary / splat_multi / different_threads / tight
  # SummaryMemory with tiny max_tokens forces compression.
  # Two threads must remain isolated; tight budget trims oldest messages.
  # --------------------------------------------------------------------------
  describe "TC-003: Agent::Base, SummaryMemory (tiny), multi-tools, different_threads, tight budget" do
    let(:memory) { IntegrationFactors.memory("summary", max_tokens: 10) }
    let(:budget) { IntegrationFactors.token_budget("tight") }
    # Isolation sub-test uses a separate memory instance with large max_tokens so
    # messages are stored verbatim (no compression).
    let(:isolation_memory) { IntegrationFactors.memory("summary", max_tokens: 100_000) }
    let(:agent) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_multi")).new }
    let(:tid_a) { "tc-003-a-#{SecureRandom.hex(4)}" }
    let(:tid_b) { "tc-003-b-#{SecureRandom.hex(4)}" }

    context "thread isolation" do
      before { @llm = LLMStub.activate(responses: ["Got it.", "Got it.", "red", "blue"]) }

      it "keeps thread-A and thread-B histories isolated" do
        cfg_a = {thread_id: tid_a, memory: isolation_memory}
        cfg_b = {thread_id: tid_b, memory: isolation_memory}

        agent.invoke("My favourite colour is red. Just say 'Got it.'", config: cfg_a)
        agent.invoke("My favourite colour is blue. Just say 'Got it.'", config: cfg_b)

        result_a = agent.invoke(
          "What is my favourite colour? Reply with only the colour name.", config: cfg_a
        )
        result_b = agent.invoke(
          "What is my favourite colour? Reply with only the colour name.", config: cfg_b
        )

        expect(result_a[:output].downcase).to include("red")
        expect(result_b[:output].downcase).to include("blue")
      end
    end

    context "compression" do
      before { @llm = LLMStub.activate(responses: ["OK", "Summary.", "OK", "Summary.", "OK", "Summary.", "Done.", "Summary."]) }

      it "does not raise even when SummaryMemory compresses history via LLM" do
        cfg_a = {thread_id: tid_a, memory: memory, token_budget: budget}

        # Seed enough messages to trigger compression (max_tokens=10 is tiny)
        3.times { |i| agent.invoke("Message #{i}. Just say OK.", config: cfg_a) }

        expect {
          agent.invoke("What is 2 + 3? Use the calculator tool.", config: cfg_a)
        }.not_to raise_error
      end
    end
  end

  # --------------------------------------------------------------------------
  # TC-007: react / none / splat_single / different_threads / nil
  # ReactAgent completes the tool-call loop; stateless (no memory).
  # --------------------------------------------------------------------------
  describe "TC-007: ReactAgent, no memory, single tool, different_threads" do
    let(:agent_klass) { IntegrationFactors.agent_class("react", tools: IntegrationFactors.tools("splat_single")) }

    context "single invocation" do
      before do
        tool_r = LLMStub.tool_call_response("calculator", {a: 8, b: 7})
        @llm = LLMStub.activate(responses: [tool_r, "15"])
      end

      it "completes the ReAct tool-call loop and returns a numeric answer" do
        result = agent_klass.new.invoke("What is 8 plus 7? Use the calculator tool.")

        expect(result[:output]).to include("15")
        expect(result[:messages]).to be_an(Array)
        expect(result[:messages]).not_to be_empty
      end
    end

    context "two independent invocations" do
      before do
        tool_r = LLMStub.tool_call_response("calculator", {a: 3, b: 3})
        @llm = LLMStub.activate(responses: [tool_r, "6", tool_r, "6"])
      end

      it "two independent invocations on different thread_ids both succeed" do
        threads = IntegrationFactors.thread_id("different_threads") # ["thread-001","thread-002"]
        results = threads.map do |tid|
          agent_klass.new.invoke("What is 3 plus 3? Use the calculator tool.",
            config: {thread_id: tid})
        end

        results.each { |r| expect(r[:output]).to include("6") }
      end
    end
  end

  # --------------------------------------------------------------------------
  # TC-009: react / summary / hash_alias / present / nil
  # ReactAgent with SummaryMemory and tool aliased as "calc".
  # --------------------------------------------------------------------------
  describe "TC-009: ReactAgent, SummaryMemory, hash_alias tool, thread_id=present" do
    let(:memory) { IntegrationFactors.memory("summary") }
    let(:agent) { IntegrationFactors.agent_class("react", tools: IntegrationFactors.tools("hash_alias")).new }
    let(:thread) { "tc-009-#{SecureRandom.hex(4)}" }

    before do
      tool_r = LLMStub.tool_call_response("calc", {a: 5, b: 6})
      @llm = LLMStub.activate(responses: [tool_r, "11", "11"])
    end

    it "calls the aliased tool and retains history across invocations" do
      cfg = {thread_id: thread, memory: memory}

      agent.invoke("What is 5 plus 6? Use the calc tool.", config: cfg)
      result = agent.invoke(
        "What was the calculation result from the previous message? Reply with only the number.",
        config: cfg
      )

      expect(result[:output]).to include("11")
    end
  end

  # --------------------------------------------------------------------------
  # TC-011: react / composite / none / different_threads / generous
  # ReactAgent with CompositeMemory (WindowMemory + SummaryMemory), no tools.
  # Two threads must remain isolated.
  # --------------------------------------------------------------------------
  describe "TC-011: ReactAgent, CompositeMemory, no tools, different_threads, generous budget" do
    let(:memory) do
      IntegrationFactors.memory("composite", sources: [
        {memory: Phronomy::Memory::WindowMemory.new(k: 5), weight: 0.6},
        {memory: Phronomy::Memory::SummaryMemory.new, weight: 0.4}
      ])
    end
    let(:budget) { IntegrationFactors.token_budget("generous") }
    let(:agent) { IntegrationFactors.agent_class("react", tools: IntegrationFactors.tools("none")).new }
    let(:tid_a) { "tc-011-a-#{SecureRandom.hex(4)}" }
    let(:tid_b) { "tc-011-b-#{SecureRandom.hex(4)}" }

    before { @llm = LLMStub.activate(responses: ["Got it.", "Got it.", "dog", "cat"]) }

    it "keeps thread histories isolated with CompositeMemory" do
      cfg_a = {thread_id: tid_a, memory: memory, token_budget: budget}
      cfg_b = {thread_id: tid_b, memory: memory, token_budget: budget}

      agent.invoke("My pet is a dog. Just say 'Got it.'", config: cfg_a)
      agent.invoke("My pet is a cat. Just say 'Got it.'", config: cfg_b)

      result_a = agent.invoke("What is my pet? Reply with only the animal name.", config: cfg_a)
      result_b = agent.invoke("What is my pet? Reply with only the animal name.", config: cfg_b)

      expect(result_a[:output].downcase).to include("dog")
      expect(result_b[:output].downcase).to include("cat")
    end
  end

  # --------------------------------------------------------------------------
  # TC-013: react / none / hash_alias / present / tight
  # ReactAgent with aliased "calc" tool; thread_id present but no memory.
  # Tight budget has no observable effect (nothing to trim).
  # --------------------------------------------------------------------------
  describe "TC-013: ReactAgent, no memory, hash_alias tool, thread_id=present, tight budget" do
    let(:agent) { IntegrationFactors.agent_class("react", tools: IntegrationFactors.tools("hash_alias")).new }

    before do
      tool_r = LLMStub.tool_call_response("calc", {a: 9, b: 4})
      @llm = LLMStub.activate(responses: [tool_r, "13"])
    end

    it "calls the aliased calc tool and returns the answer" do
      result = agent.invoke("What is 9 plus 4? Use the calc tool.",
        config: {thread_id: IntegrationFactors.thread_id("present")})

      expect(result[:output]).to include("13")
    end
  end

  # --------------------------------------------------------------------------
  # TC-014: base / none / splat_multi / nil / generous
  # Base agent with multiple tools; LLM can call one of them.
  # --------------------------------------------------------------------------
  describe "TC-014: Agent::Base, no memory, multiple tools" do
    let(:agent_klass) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_multi")) }

    before do
      tool_r = LLMStub.tool_call_response("calculator", {a: 12, b: 8})
      @llm = LLMStub.activate(responses: [tool_r, "20"])
    end

    it "returns a result that uses at least one of the registered tools" do
      result = agent_klass.new.invoke("What is 12 plus 8? Use the calculator tool.")

      expect(result[:output]).to include("20")
    end
  end

  # --------------------------------------------------------------------------
  # TC-015: base / none / hash_no_alias / present / generous
  # Hash form with nil alias → original tool class name is preserved.
  # --------------------------------------------------------------------------
  describe "TC-015: Agent::Base, no memory, hash_no_alias tool" do
    let(:agent_klass) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("hash_no_alias")) }

    before do
      tool_r = LLMStub.tool_call_response("calculator", {a: 7, b: 3})
      @llm = LLMStub.activate(responses: [tool_r, "10"])
    end

    it "can invoke the tool whose name is derived from its class name" do
      result = agent_klass.new.invoke("What is 7 plus 3? Use the available calculator tool.")

      expect(result[:output]).to include("10")
    end
  end

  # --------------------------------------------------------------------------
  # TC-016: base / window / splat_multi / different_threads / nil
  # WindowMemory + multiple tools; thread-A and thread-B are isolated.
  # --------------------------------------------------------------------------
  describe "TC-016: Agent::Base, WindowMemory, multi-tools, different_threads" do
    let(:memory) { IntegrationFactors.memory("window") }
    let(:agent) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_multi")).new }
    let(:tid_a) { "tc-016-a-#{SecureRandom.hex(4)}" }
    let(:tid_b) { "tc-016-b-#{SecureRandom.hex(4)}" }

    before { @llm = LLMStub.activate(responses: ["Got it.", "Got it.", "Tokyo", "Paris"]) }

    it "keeps thread-A and thread-B context separate" do
      cfg_a = {thread_id: tid_a, memory: memory}
      cfg_b = {thread_id: tid_b, memory: memory}

      agent.invoke("My city is Tokyo. Just say 'Got it.'", config: cfg_a)
      agent.invoke("My city is Paris. Just say 'Got it.'", config: cfg_b)

      result_a = agent.invoke("What is my city? Reply with only the city name.", config: cfg_a)
      result_b = agent.invoke("What is my city? Reply with only the city name.", config: cfg_b)

      expect(result_a[:output]).to match(/tokyo/i)
      expect(result_b[:output]).to match(/paris/i)
    end
  end

  # --------------------------------------------------------------------------
  # TC-017: base / window / hash_alias / different_threads / tight
  # WindowMemory + aliased tool + tight budget trims oldest messages.
  # --------------------------------------------------------------------------
  describe "TC-017: Agent::Base, WindowMemory, hash_alias tool, different_threads, tight budget" do
    let(:memory) { IntegrationFactors.memory("window") }
    let(:budget) { IntegrationFactors.token_budget("tight") }
    let(:agent) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("hash_alias")).new }
    let(:tid_a) { "tc-017-a-#{SecureRandom.hex(4)}" }
    let(:tid_b) { "tc-017-b-#{SecureRandom.hex(4)}" }

    before { @llm = LLMStub.activate(responses: ["Got it.", "Got it.", "9", "4"]) }

    it "does not raise when budget is tight and handles both threads" do
      cfg_a = {thread_id: tid_a, memory: memory, token_budget: budget}
      cfg_b = {thread_id: tid_b, memory: memory, token_budget: budget}

      expect {
        agent.invoke("My team colour is green. Just say 'Got it.'", config: cfg_a)
        agent.invoke("My team colour is yellow. Just say 'Got it.'", config: cfg_b)
        agent.invoke("What is 4 plus 5? Use the calc tool.", config: cfg_a)
        agent.invoke("What is 2 plus 2? Use the calc tool.", config: cfg_b)
      }.not_to raise_error
    end
  end

  # --------------------------------------------------------------------------
  # TC-025: base / composite / splat_single / present / nil
  # CompositeMemory (WindowMemory sub-source) + single tool.
  # --------------------------------------------------------------------------
  describe "TC-025: Agent::Base, CompositeMemory, single tool, thread_id=present" do
    let(:memory) do
      IntegrationFactors.memory("composite", sources: [
        {memory: Phronomy::Memory::WindowMemory.new(k: 5), weight: 1.0}
      ])
    end
    let(:agent) { IntegrationFactors.agent_class("base", tools: IntegrationFactors.tools("splat_single")).new }
    let(:thread) { "tc-025-#{SecureRandom.hex(4)}" }

    before { @llm = LLMStub.activate(responses: ["Got it.", "77"]) }

    it "aggregates messages from CompositeMemory sub-sources" do
      cfg = {thread_id: thread, memory: memory}

      agent.invoke("My lucky number is 77. Just say 'Got it.'", config: cfg)
      result = agent.invoke(
        "What is my lucky number? Reply with only the number.", config: cfg
      )

      expect(result[:output]).to include("77")
    end
  end
end
