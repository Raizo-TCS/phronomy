# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 10: PromptTemplate
# Pairwise factors: prompt_template_type × template_variable_supply ×
#                   agent_instructions_type
# Generated stubs: 8 cases (LLMChain and SequentialChain excluded — removed from library)

RSpec.describe "Group 10: PromptTemplate", :integration do
  # ---------------------------------------------------------------------------
  # TC-001: human_only template, all_provided, template_only
  #         Pure Ruby — no LLM required
  # ---------------------------------------------------------------------------
  describe "TC-001: PromptTemplate human_only; all variables provided; standalone invoke" do
    it "returns a Hash with :prompt and without :system" do
      tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(template: "What is the capital of {{country}}?")
      result = tmpl.invoke({country: "Japan"})
      expect(result[:prompt]).to eq("What is the capital of Japan?")
      expect(result).not_to have_key(:system)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: PromptTemplate with_system; missing_one variable; template_only
  #         Pure Ruby
  # ---------------------------------------------------------------------------
  describe "TC-006: PromptTemplate with_system; missing variable; standalone invoke" do
    it "raises KeyError when a system_template variable is absent" do
      tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        template: "{{question}}",
        system_template: "You are a {{role}} assistant."
      )
      expect { tmpl.invoke({question: "Hi"}) }.to raise_error(KeyError, /role/)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: PromptTemplate with_system; all_provided; template_only
  #         Pure Ruby
  # ---------------------------------------------------------------------------
  describe "TC-009: PromptTemplate with_system; all_provided; standalone — :system key present" do
    it "includes :system in the invoke result" do
      tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
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
      tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}."
      )
      result = tmpl.invoke({text: "Hello", source_lang: "English", target_lang: "French"})
      expect(result[:prompt]).to eq("Translate Hello from English to French.")
    end

    it "reports all variable names via #variables" do
      tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        template: "Translate {{text}} from {{source_lang}} to {{target_lang}}."
      )
      expect(tmpl.variables).to match_array(%i[text source_lang target_lang])
    end
  end

  # ---------------------------------------------------------------------------
  # TC-013: multi_variable template + prompt_template instructions on Agent::Base
  # ---------------------------------------------------------------------------
  describe "TC-013: Agent::Base with PromptTemplate instructions; multi_variable" do
    before { @llm = LLMStub.activate(responses: ["4"]) }
    after { LLMStub.deactivate }

    it "injects system_template as system prompt and returns non-empty output", :llm_required do
      tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
        template: "Answer this in {{lang}}: {{question}}",
        system_template: "You are a {{domain}} expert. Be concise."
      )

      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-13", version: 1
        model IntegrationFactors::LM_STUDIO_MODEL
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
end
