# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Pairwise integration test cases — Group 12: EntityMemory
#
# Source:   docs/integration_test_factors.yaml
# Factors:  entity_memory_input, entity_memory_recall_query, entity_memory_thread_isolation
# Generated cases: 20
#
# Feasible:
#   TC-001, TC-004, TC-006, TC-008, TC-011, TC-012, TC-016, TC-020
#
# Infeasible (entity mismatch — input entity != queried entity; LLM response undefined):
#   TC-002, TC-003, TC-005, TC-007, TC-009, TC-010, TC-013, TC-014, TC-015
#
# Infeasible (no entity stored, entity-specific query has no ground truth):
#   TC-017, TC-018, TC-019
#
# LLM calls are intercepted by LLMStub so these tests run without LM Studio.
# Each example group configures stub responses and asserts on the messages
# array that Phronomy sent to the LLM, verifying that EntityMemory injects
# the entity context system message correctly.

RSpec.describe "Group 12: EntityMemory", :integration do
  # Helper: build an agent that answers directly from context without tools.
  def entity_agent
    Class.new(Phronomy::Agent::Base) do
      model "openai/gpt-oss-20b"
      provider :openai
      instructions "You are a helpful assistant. Answer directly from the provided context. Do not call any tools."
    end.new
  end

  # --------------------------------------------------------------------------
  # TC-001: name / ask_name / single_thread
  # EntityMemory extracts :name from user input (regex) and injects it as a
  # system context message on the second call.  The stub verifies the injected
  # message is present and returns the configured entity value as the response.
  # --------------------------------------------------------------------------
  describe "TC-001: entity=name, query=ask_name, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "Alice"]) }
    after { LLMStub.deactivate }

    it "extracts :name entity and injects it as a context system message on the second LLM call" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-001-#{SecureRandom.hex(4)}"

      agent.invoke("My name is Alice. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory})

      expect(memory.entities_for(thread)[:name]).to eq("Alice")

      result = agent.invoke(
        "What is my name? Reply with only the name, nothing else.",
        config: {thread_id: thread, memory: memory}
      )

      # EntityMemory must inject the entity_facts context block into the second LLM call
      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*name.*Alice/m)
      )
      expect(result[:output]).to match(/alice/i)
    end
  end

  # --------------------------------------------------------------------------
  # TC-002: name / ask_workplace / two_threads — INFEASIBLE
  # Input entity (:name) does not match queried entity (:workplace).
  # LLM response when workplace is unknown is undefined.
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch — name stored but workplace queried; undefined LLM response

  # --------------------------------------------------------------------------
  # TC-003: name / ask_location / single_thread — INFEASIBLE
  # Same mismatch as TC-002.
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch — name stored but location queried; undefined LLM response

  # --------------------------------------------------------------------------
  # TC-004: name / ask_unrelated / single_thread
  # Entity context is injected but the query is purely mathematical.
  # Verifies the entity system message is present and does not corrupt the response.
  # --------------------------------------------------------------------------
  describe "TC-004: entity=name, query=ask_unrelated, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "4"]) }
    after { LLMStub.deactivate }

    it "injects :name entity context system message even for unrelated queries" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-004-#{SecureRandom.hex(4)}"

      agent.invoke("My name is Alice. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory})

      result = agent.invoke(
        "What is 2 + 2? Reply with only the number.",
        config: {thread_id: thread, memory: memory}
      )

      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*name.*Alice/m)
      )
      expect(result[:output]).to match(/\b4\b/)
    end
  end

  # --------------------------------------------------------------------------
  # TC-005: workplace / ask_name / two_threads — INFEASIBLE
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch

  # --------------------------------------------------------------------------
  # TC-006: workplace / ask_workplace / single_thread
  # --------------------------------------------------------------------------
  describe "TC-006: entity=workplace, query=ask_workplace, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "Acme Corp"]) }
    after { LLMStub.deactivate }

    it "extracts :workplace entity and injects it as a context system message on the second LLM call" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-006-#{SecureRandom.hex(4)}"

      agent.invoke("I work at Acme Corp. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory})

      expect(memory.entities_for(thread)[:workplace]).to eq("Acme Corp")

      result = agent.invoke(
        "Where do I work? Reply with only the company name.",
        config: {thread_id: thread, memory: memory}
      )

      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*workplace.*Acme/m)
      )
      expect(result[:output]).to match(/acme/i)
    end
  end

  # --------------------------------------------------------------------------
  # TC-007: workplace / ask_location / two_threads — INFEASIBLE
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch

  # --------------------------------------------------------------------------
  # TC-008: workplace / ask_unrelated / two_threads
  # Two threads share the same EntityMemory instance.
  # Thread t1 stores :workplace; t2 stores nothing.
  # Verifies the entity system message is injected for t1 and t2 is isolated.
  # --------------------------------------------------------------------------
  describe "TC-008: entity=workplace, query=ask_unrelated, two_threads" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "4"]) }
    after { LLMStub.deactivate }

    it "injects entity context for t1; t2 entity store remains isolated" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      t1 = "em-008-t1-#{SecureRandom.hex(4)}"
      t2 = "em-008-t2-#{SecureRandom.hex(4)}"

      agent.invoke("I work at Acme Corp. Just say 'Got it.'",
        config: {thread_id: t1, memory: memory})

      result_t1 = agent.invoke(
        "What is 2 + 2? Reply with only the number.",
        config: {thread_id: t1, memory: memory}
      )

      # t1: entity context must be present even for unrelated queries
      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*workplace.*Acme/m)
      )
      expect(result_t1[:output]).to match(/\b4\b/)

      # t2: no entity must have leaked from t1
      expect(memory.entities_for(t2)).to be_empty
    end
  end

  # --------------------------------------------------------------------------
  # TC-009: location / ask_name / single_thread — INFEASIBLE
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch

  # --------------------------------------------------------------------------
  # TC-010: location / ask_workplace / two_threads — INFEASIBLE
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch

  # --------------------------------------------------------------------------
  # TC-011: location / ask_location / single_thread
  # --------------------------------------------------------------------------
  describe "TC-011: entity=location, query=ask_location, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "Tokyo"]) }
    after { LLMStub.deactivate }

    it "extracts :location entity and injects it as a context system message on the second LLM call" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-011-#{SecureRandom.hex(4)}"

      agent.invoke("I live in Tokyo. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory})

      expect(memory.entities_for(thread)[:location]).to eq("Tokyo")

      result = agent.invoke(
        "Where do I live? Reply with only the city name.",
        config: {thread_id: thread, memory: memory}
      )

      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*location.*Tokyo/m)
      )
      expect(result[:output]).to match(/tokyo/i)
    end
  end

  # --------------------------------------------------------------------------
  # TC-012: location / ask_unrelated / single_thread
  # --------------------------------------------------------------------------
  describe "TC-012: entity=location, query=ask_unrelated, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "4"]) }
    after { LLMStub.deactivate }

    it "injects :location entity context system message even for unrelated queries" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-012-#{SecureRandom.hex(4)}"

      agent.invoke("I live in Tokyo. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory})

      result = agent.invoke(
        "What is 2 + 2? Reply with only the number.",
        config: {thread_id: thread, memory: memory}
      )

      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*location.*Tokyo/m)
      )
      expect(result[:output]).to match(/\b4\b/)
    end
  end

  # --------------------------------------------------------------------------
  # TC-013: preference / ask_name / single_thread — INFEASIBLE
  # TC-014: preference / ask_workplace / two_threads — INFEASIBLE
  # TC-015: preference / ask_location / single_thread — INFEASIBLE
  # --------------------------------------------------------------------------
  # SKIP: entity mismatch

  # --------------------------------------------------------------------------
  # TC-016: preference / ask_unrelated / single_thread
  # --------------------------------------------------------------------------
  describe "TC-016: entity=preference, query=ask_unrelated, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Got it.", "4"]) }
    after { LLMStub.deactivate }

    it "injects :preference entity context system message even for unrelated queries" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-016-#{SecureRandom.hex(4)}"

      agent.invoke("I like Ruby. Just say 'Got it.'",
        config: {thread_id: thread, memory: memory})

      expect(memory.entities_for(thread)[:preference]).to eq("Ruby")

      result = agent.invoke(
        "What is 2 + 2? Reply with only the number.",
        config: {thread_id: thread, memory: memory}
      )

      # EntityMemory must inject the entity_facts context block into the second LLM call
      expect(@llm.messages_for(1)).to include(
        hash_including("content" => /entity_facts.*preference.*Ruby/m)
      )
      expect(result[:output]).to match(/\b4\b/)
    end
  end

  # --------------------------------------------------------------------------
  # TC-017: no_entity / ask_name / single_thread — INFEASIBLE
  # TC-018: no_entity / ask_workplace / two_threads — INFEASIBLE
  # TC-019: no_entity / ask_location / single_thread — INFEASIBLE
  # No entity is stored so the query has no ground truth to check against.
  # --------------------------------------------------------------------------

  # --------------------------------------------------------------------------
  # TC-020: no_entity / ask_unrelated / single_thread
  # No entity is extracted; verifies that EntityMemory does NOT inject any
  # entity context system message when the entity store is empty.
  # --------------------------------------------------------------------------
  describe "TC-020: entity=no_entity, query=ask_unrelated, single_thread" do
    before { @llm = LLMStub.activate(responses: ["Hello!", "4"]) }
    after { LLMStub.deactivate }

    it "sends no entity context system message when no entity was extracted" do
      memory = Phronomy::Memory::EntityMemory.new
      agent = entity_agent
      thread = "em-020-#{SecureRandom.hex(4)}"

      agent.invoke("Hello, how are you? Just say 'Hello!'",
        config: {thread_id: thread, memory: memory})

      expect(memory.entities_for(thread)).to be_empty

      result = agent.invoke(
        "What is 2 + 2? Reply with only the number.",
        config: {thread_id: thread, memory: memory}
      )

      # With no entities, no entity_facts context message must be injected
      entity_system_messages = @llm.messages_for(1).select do |m|
        m["role"] == "system" && m["content"].to_s.include?("entity_facts")
      end
      expect(entity_system_messages).to be_empty
      expect(result[:output]).to match(/\b4\b/)
    end
  end
end
