# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 10: PromptTemplate / LLMChain / SequentialChain
# Pairwise factors: prompt_template_type × template_variable_supply ×
#                   chain_composition × agent_instructions_type
# Generated stubs: 13 cases
#
# Infeasible cases (skipped):
#   TC-003: sequential_three (PromptTemplate >> LLMChain >> OutputParser) — LLMChain returns
#           a Hash { output:, usage: }, OutputParser expects a String; incompatible types.
#   TC-007: with_system + missing_one + sequential_three — same incompatibility
#   TC-012: multi_variable + sequential_three — same incompatibility
#
# LLM-required cases (LM Studio connection):
#   TC-004: LLMChain standalone, String input
#   TC-005: PromptTemplate with_system >> LLMChain (template_then_llm)
#   TC-013: multi_variable + llm_only + prompt_template instructions (Agent::Base)
#
# Pure-Ruby / no-LLM cases: TC-001, TC-002, TC-006, TC-009, TC-010, TC-011

LM_MODEL_10 = IntegrationFactors::LM_STUDIO_MODEL

RSpec.describe "Group 10: PromptTemplate / Chain", :integration do
  # ---------------------------------------------------------------------------
  # TC-001: human_only template, all_provided, template_only
  #         Pure Ruby — no LLM required
  # ---------------------------------------------------------------------------
  describe "TC-001: PromptTemplate human_only; all variables provided; standalone invoke" do
    it "returns a Hash with :prompt and without :system" do
      tmpl = Phronomy::Chain::PromptTemplate.new(template: "What is the capital of {{country}}?")
      result = tmpl.invoke({country: "Japan"})
      expect(result[:prompt]).to eq("What is the capital of Japan?")
      expect(result).not_to have_key(:system)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: human_only template, missing_one variable, template_then_llm chain
  #         Pure Ruby — no LLM required (KeyError raised before LLM call)
  # ---------------------------------------------------------------------------
  describe "TC-002: PromptTemplate human_only; missing variable; template_then_llm" do
    it "raises KeyError before reaching LLM" do
      # Build a chain; LLM is never called because template raises first
      tmpl = Phronomy::Chain::PromptTemplate.new(template: "Translate {{text}} to {{lang}}")
      fake_llm = Object.new
      fake_llm.define_singleton_method(:invoke) { |_input, config: {}| raise "should not reach here" }

      chain = tmpl >> fake_llm
      expect { chain.invoke({text: "Hello"}) }.to raise_error(KeyError, /lang/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: LLMChain standalone; human_only prompt_template_type; all_provided;
  #         llm_only chain; proc instructions  [LLM REQUIRED]
  # ---------------------------------------------------------------------------
  describe "TC-004: LLMChain standalone; String input" do
    it "returns non-empty :output and a TokenUsage" do
      chain = Phronomy::Chain::LLMChain.new(model: LM_MODEL_10, provider: :openai)
      result = chain.invoke("Reply with the single word: pong.")
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
      expect(result[:usage]).to be_a(Phronomy::TokenUsage)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: PromptTemplate with_system >> LLMChain; all_provided  [LLM REQUIRED]
  # ---------------------------------------------------------------------------
  describe "TC-005: PromptTemplate with_system >> LLMChain; all variables provided" do
    it "sends system prompt and returns non-empty output" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "Reply with a one-word answer to: {{question}}",
        system_template: "You are a {{role}} assistant. Keep answers extremely short."
      )
      llm = Phronomy::Chain::LLMChain.new(model: LM_MODEL_10, provider: :openai)
      chain = tmpl >> llm

      result = chain.invoke({question: "What is 2+2?", role: "math"})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: PromptTemplate with_system; missing_one variable; template_only
  #         Pure Ruby
  # ---------------------------------------------------------------------------
  describe "TC-006: PromptTemplate with_system; missing variable; standalone invoke" do
    it "raises KeyError when a system_template variable is absent" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "{{question}}",
        system_template: "You are a {{role}} assistant."
      )
      # :role is missing from the input
      expect { tmpl.invoke({question: "Hi"}) }.to raise_error(KeyError, /role/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: PromptTemplate with_system; missing_one variable; llm_only
  #         Pure Ruby — missing_one applies to template, llm_only means we call
  #         LLMChain directly (which doesn't validate template variables)
  # ---------------------------------------------------------------------------
  describe "TC-008: LLMChain accepts Hash with :prompt key directly" do
    it "raises ArgumentError for a Hash without :prompt" do
      chain = Phronomy::Chain::LLMChain.new(model: LM_MODEL_10, provider: :openai)
      expect { chain.invoke({language: "Ruby"}) }.to raise_error(ArgumentError, /prompt key/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: PromptTemplate with_system; all_provided; template_only; proc instructions
  #         Pure Ruby
  # ---------------------------------------------------------------------------
  describe "TC-009: PromptTemplate with_system; all_provided; standalone — :system key present" do
    it "includes :system in the invoke result" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "{{question}}",
        system_template: "You are a {{role}} expert."
      )
      result = tmpl.invoke({question: "What is Ruby?", role: "programming"})
      expect(result[:prompt]).to eq("What is Ruby?")
      expect(result[:system]).to eq("You are a programming expert.")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: multi_variable template; all_provided; template_only
  #         Pure Ruby
  # ---------------------------------------------------------------------------
  describe "TC-010: multi_variable PromptTemplate; all variables provided; standalone" do
    it "substitutes all variables correctly" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}."
      )
      result = tmpl.invoke({text: "Hello", source_lang: "English", target_lang: "French"})
      expect(result[:prompt]).to eq("Translate Hello from English to French.")
    end

    it "reports all variable names via #variables" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}."
      )
      expect(tmpl.variables).to match_array(%i[text source_lang target_lang])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: multi_variable template; missing_one; template_then_llm
  #         Pure Ruby — KeyError before LLM
  # ---------------------------------------------------------------------------
  describe "TC-011: multi_variable PromptTemplate; missing variable in >> chain" do
    it "raises KeyError and never calls LLM" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "{{a}} + {{b}} = {{c}}"
      )
      fake_llm = Object.new
      fake_llm.define_singleton_method(:invoke) { |_i, config: {}| raise "should not be called" }

      chain = tmpl >> fake_llm
      expect { chain.invoke({a: "1", b: "2"}) }.to raise_error(KeyError, /c/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-013: multi_variable template + prompt_template instructions on Agent::Base
  #         [LLM REQUIRED]
  # ---------------------------------------------------------------------------
  describe "TC-013: Agent::Base with PromptTemplate instructions; multi_variable; llm_only" do
    it "injects system_template as system prompt and returns non-empty output" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "Answer this in {{lang}}: {{question}}",
        system_template: "You are a {{domain}} expert. Be concise."
      )

      klass = Class.new(Phronomy::Agent::Base) do
        model LM_MODEL_10
        provider :openai
        instructions tmpl
      end

      result = klass.new.invoke({
        lang: "English",
        question: "What is 2+2?",
        domain: "math"
      })

      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # SequentialChain pipeline: PromptTemplate >> LLMChain (template_then_llm)
  # Verifies >> operator produces correct result end-to-end  [LLM REQUIRED]
  # ---------------------------------------------------------------------------
  describe "SequentialChain (>>) end-to-end: PromptTemplate >> LLMChain" do
    it "pipes template output into LLMChain and returns final :output" do
      tmpl = Phronomy::Chain::PromptTemplate.new(
        template: "Give a one-sentence definition of {{concept}}.",
        system_template: "You are a helpful educator. Keep it short."
      )
      llm = Phronomy::Chain::LLMChain.new(model: LM_MODEL_10, provider: :openai)
      chain = tmpl >> llm

      result = chain.invoke({concept: "recursion"})
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end
end
