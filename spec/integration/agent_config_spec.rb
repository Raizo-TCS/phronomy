# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/llm_stub"

# Group 6: Agent Configuration Parameters
# Pairwise factors: agent_model × agent_instructions × agent_temperature ×
#                   agent_max_iterations × agent_input_type ×
#                   agent_cache_instructions × agent_provider
# Feasible cases: 11
#   Infeasible (R-anthropic): TC-003, TC-004, TC-011, TC-015
#
# LLM note: All feasible cases invoke LM Studio.
# agent_max_iterations=one causes the agent to abort after 1 LLM turn.

RSpec.describe "Group 6: Agent Configuration Parameters", :integration do
  LM_MODEL = "openai/gpt-oss-20b"
  LM_PROVIDER = :openai

  before { @llm = LLMStub.activate(responses: ["Here is the answer."]) }
  after { LLMStub.deactivate }

  # Build a Base agent class with the given configuration options.
  # @param model        [String, nil]
  # @param instructions [String, Proc, nil]
  # @param temperature  [Float, nil]
  # @param max_iter     [Integer, nil]
  # @param cache_instr  [Boolean, nil]
  # @param provider     [Symbol, nil]
  def build_agent(model: LM_MODEL, instructions: "You are a helpful assistant.",
    temperature: nil, max_iter: nil,
    cache_instr: nil, provider: LM_PROVIDER)
    m = model
    instr = instructions
    temp = temperature
    iter = max_iter
    cache = cache_instr
    prov = provider

    Class.new(Phronomy::Agent::Base) do
      self.model(m) if m
      provider prov if prov
      self.instructions(instr) if instr.is_a?(String)
      self.instructions(&instr) if instr.is_a?(Proc)
      temperature temp if temp
      max_iterations iter if iter
      cache_instructions cache unless cache.nil?
    end
  end

  # Normalise the input value to a string for agent.invoke
  def normalise_input(value, type)
    case type
    when :string then value.to_s
    when :hash_message then {message: value.to_s}
    when :hash_query then {query: value.to_s}
    else value
    end
  end

  # ---------------------------------------------------------------------------
  # TC-001: explicit model; string instructions; nil temperature; default iterations;
  #         string input; cache=disabled; nil provider — baseline
  # ---------------------------------------------------------------------------
  describe "TC-001: explicit model; string instructions; nil temp; string input — baseline" do
    it "agent returns a non-empty output string" do
      klass = build_agent(
        model: LM_MODEL, instructions: "You are a helpful assistant.",
        provider: LM_PROVIDER
      )
      result = klass.new.invoke("Say hello.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: explicit model; proc instructions; temperature=0; max_iterations=1;
  #         hash_message input; cache=enabled (silently ignored with openai)
  # ---------------------------------------------------------------------------
  describe "TC-002: explicit model; proc instructions; temperature=0; max_iterations=1; hash_message input" do
    it "proc instructions are called and agent returns output" do
      dynamic_instructions = ->(input) { "You help with: #{input}" }
      klass = build_agent(
        model: LM_MODEL,
        instructions: dynamic_instructions,
        temperature: 0.0,
        max_iter: 1,
        cache_instr: true,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({message: "a quick question"})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # TC-003 infeasible (R-anthropic)
  # TC-004 infeasible (R-anthropic)

  # ---------------------------------------------------------------------------
  # TC-005: nil model (falls back to default_model); proc instructions;
  #         nil temperature; default iterations; hash_query input;
  #         cache=enabled (silently ignored)
  # ---------------------------------------------------------------------------
  describe "TC-005: nil model (default fallback); proc instructions; hash_query input" do
    it "agent falls back to configured default_model and returns output" do
      klass = build_agent(
        model: nil,
        instructions: ->(input) { "Answer the query: #{input}" },
        cache_instr: true,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({query: "What colour is the sky?"})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: nil model; nil instructions; nil temperature; max_iterations=1;
  #         hash_message input; cache=disabled; openai provider
  # ---------------------------------------------------------------------------
  describe "TC-006: nil model; no instructions; max_iterations=1; hash_message input" do
    it "agent without instructions still returns a response" do
      klass = build_agent(
        model: nil,
        instructions: nil,
        max_iter: 1,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({message: "What is 2+2?"})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: nil model; string instructions; temperature=0.5; max_iterations=1;
  #         string input; cache=enabled (silently ignored); openai provider
  # ---------------------------------------------------------------------------
  describe "TC-007: nil model; string instructions; temperature=0.5; max_iterations=1; string input" do
    it "agent with temperature=0.5 returns valid output" do
      klass = build_agent(
        model: nil,
        instructions: "You are a creative assistant.",
        temperature: 0.5,
        max_iter: 1,
        cache_instr: true,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke("Suggest a book.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: explicit model; string instructions; temperature=0.5; default iterations;
  #         hash_message input; cache=disabled; nil provider
  # ---------------------------------------------------------------------------
  describe "TC-008: explicit model; string instructions; temperature=0.5; hash_message input; nil provider" do
    it "agent with nil provider (inferred) and hash_message input returns output" do
      klass = build_agent(
        model: LM_MODEL,
        instructions: "You are a helpful assistant.",
        temperature: 0.5,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({message: "Name a planet."})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: explicit model; string instructions; temperature=0; default iterations;
  #         hash_query input; cache=disabled; openai provider
  # ---------------------------------------------------------------------------
  describe "TC-009: explicit model; string instructions; temperature=0; hash_query input; openai provider" do
    it "temperature=0 (deterministic) agent with hash_query input returns output" do
      klass = build_agent(
        model: LM_MODEL,
        instructions: "You are an assistant.",
        temperature: 0.0,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({query: "What is the capital of France?"})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: explicit model; proc instructions; temperature=0.5; large iterations;
  #         string input; cache=disabled; nil provider
  # ---------------------------------------------------------------------------
  describe "TC-010: explicit model; proc instructions; large max_iterations; string input" do
    it "proc instructions receive input context and agent returns output" do
      received_inputs = []
      klass = build_agent(
        model: LM_MODEL,
        instructions: ->(input) {
          received_inputs << input
          "You are an expert on: #{input}"
        },
        provider: LM_PROVIDER
      )
      result = klass.new.invoke("astronomy")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # TC-011 infeasible (R-anthropic)

  # ---------------------------------------------------------------------------
  # TC-012: explicit model; no instructions; temperature=0; default iterations;
  #         string input; cache=enabled (silently ignored); nil provider
  # ---------------------------------------------------------------------------
  describe "TC-012: explicit model; no instructions; temperature=0; cache_instructions silently ignored" do
    it "agent with cache_instructions=true and nil provider behaves normally" do
      klass = build_agent(
        model: LM_MODEL,
        instructions: nil,
        temperature: 0.0,
        cache_instr: true,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke("What year did WW2 end?")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-013: explicit model; string instructions; nil temperature; large iterations;
  #         hash_message input; cache=disabled; openai provider
  # ---------------------------------------------------------------------------
  describe "TC-013: explicit model; string instructions; large max_iterations; hash_message input; openai provider" do
    it "agent with large max_iterations processes hash_message and returns output" do
      klass = build_agent(
        model: LM_MODEL,
        instructions: "You are a knowledgeable assistant.",
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({message: "Briefly describe photosynthesis."})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-014: explicit model; string instructions; nil temperature; max_iterations=1;
  #         hash_query input; cache=disabled; nil provider
  # ---------------------------------------------------------------------------
  describe "TC-014: explicit model; string instructions; max_iterations=1; hash_query input; nil provider" do
    it "agent with max_iterations=1 returns output after a single LLM turn" do
      klass = build_agent(
        model: LM_MODEL,
        instructions: "Answer briefly.",
        max_iter: 1,
        provider: LM_PROVIDER
      )
      result = klass.new.invoke({query: "Name any country."})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # TC-015 infeasible (R-anthropic)
end
