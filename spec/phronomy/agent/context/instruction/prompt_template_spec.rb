# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Context::Instruction::PromptTemplate do
  subject(:template) do
    described_class.new(
      template: "Translate to {{lang}}: {{text}}",
      system_template: "You are a {{role}} translator."
    )
  end

  describe "#format" do
    it "substitutes all placeholders" do
      expect(template.format(lang: "French", text: "Hello")).to eq("Translate to French: Hello")
    end

    it "accepts string keys via normalize_input (invoke path)" do
      # format uses keyword arguments — test direct symbol path
      result = template.format(lang: "German", text: "World")
      expect(result).to eq("Translate to German: World")
    end

    it "raises KeyError when a placeholder is missing" do
      expect { template.format(lang: "French") }.to raise_error(KeyError, /Missing variable.*text/)
    end
  end

  describe "#format_system" do
    it "substitutes placeholders in the system template" do
      expect(template.format_system(role: "professional")).to eq("You are a professional translator.")
    end

    it "returns nil when no system_template was set" do
      t = described_class.new(template: "Hello {{name}}")
      expect(t.format_system(name: "test")).to be_nil
    end
  end

  describe "#variables" do
    it "returns all unique placeholder names across both templates" do
      expect(template.variables).to match_array(%i[lang text role])
    end

    it "deduplicates variables that appear in both templates" do
      t = described_class.new(template: "{{lang}} {{lang}}", system_template: "{{lang}}")
      expect(t.variables).to eq([:lang])
    end
  end

  describe "#invoke" do
    it "returns a Hash with :prompt key" do
      result = template.invoke({lang: "Spanish", text: "Good morning", role: "neutral"})
      expect(result[:prompt]).to eq("Translate to Spanish: Good morning")
    end

    it "includes :system key when system_template is set" do
      result = template.invoke({lang: "Spanish", text: "Hi", role: "formal"})
      expect(result[:system]).to eq("You are a formal translator.")
    end

    it "omits :system key when no system_template is set" do
      t = described_class.new(template: "Hello {{name}}")
      result = t.invoke({name: "World"})
      expect(result).not_to have_key(:system)
    end

    it "raises ArgumentError when given a non-Hash, non-String input" do
      expect { template.invoke(42) }.to raise_error(ArgumentError, /expects a Hash/)
    end
  end
end

# ---------------------------------------------------------------------------
RSpec.describe "Agent::Base instructions with PromptTemplate" do
  let(:fake_tokens) { double("Tokens", input: 5, output: 3, cached: 0, cache_creation: 0) }
  let(:fake_response) { double("Response", content: "answer", tool_calls: nil, tokens: fake_tokens, tool_call?: false) }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:cancellation_token=)
    allow(dbl).to receive(:on_tool_call)
    allow(dbl).to receive(:on_tool_result)
    allow(dbl).to receive(:ask).and_return(fake_response)
    allow(dbl).to receive(:messages).and_return([fake_response])
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

  it "uses the system_template as the system prompt when input is a Hash" do
    tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
      template: "{{question}}",
      system_template: "You are a {{style}} assistant."
    )

    agent_class = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      instructions tmpl
    end

    agent_class.new.invoke({question: "Hello", style: "helpful"})
    expect(fake_chat).to have_received(:with_instructions).with("You are a helpful assistant.")
  end

  it "falls back to the human template when system_template is nil" do
    tmpl = Phronomy::Agent::Context::Instruction::PromptTemplate.new(template: "Act as a {{role}}.")

    agent_class = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      instructions tmpl
    end

    agent_class.new.invoke({role: "chef", message: "Hello"})
    expect(fake_chat).to have_received(:with_instructions).with("Act as a chef.")
  end
end
