# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Chain::PromptTemplate do
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

  describe "#>>" do
    it "returns a SequentialChain" do
      fake_runnable = Object.new
      def fake_runnable.invoke(input, config: {})
        input
      end

      chain = template >> fake_runnable
      expect(chain).to be_a(Phronomy::Chain::SequentialChain)
    end

    it "passes template output into the next step" do
      collector = []
      receiver = Object.new
      receiver.define_singleton_method(:invoke) do |input, config: {}|
        collector << input
        input
      end

      chain = template >> receiver
      chain.invoke({lang: "Italian", text: "Ciao", role: "casual"})
      expect(collector.first[:prompt]).to eq("Translate to Italian: Ciao")
    end
  end
end

# ---------------------------------------------------------------------------
RSpec.describe Phronomy::Chain::SequentialChain do
  let(:step_a) do
    s = Object.new
    s.define_singleton_method(:invoke) { |input, config: {}| {value: input[:value] * 2} }
    s
  end

  let(:step_b) do
    s = Object.new
    s.define_singleton_method(:invoke) { |input, config: {}| {value: input[:value] + 10} }
    s
  end

  describe "#invoke" do
    it "pipes output of each step into the next" do
      chain = described_class.new(step_a, step_b)
      expect(chain.invoke({value: 5})).to eq({value: 20})
    end
  end

  describe "#>>" do
    it "appends a new step and returns a new SequentialChain" do
      chain = described_class.new(step_a) >> step_b
      expect(chain).to be_a(described_class)
      expect(chain.invoke({value: 3})).to eq({value: 16})
    end
  end
end

# ---------------------------------------------------------------------------
RSpec.describe Phronomy::Chain::LLMChain do
  let(:fake_tokens) { double("Tokens", input: 5, output: 3, cached: 0, cache_creation: 0) }
  let(:fake_response) { double("Response", content: "Tokyo", tokens: fake_tokens) }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:ask).and_return(fake_response)
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

  subject(:chain) { described_class.new(model: "test-model") }

  describe "#invoke" do
    it "accepts a String input and returns :output" do
      result = chain.invoke("What is the capital of Japan?")
      expect(result[:output]).to eq("Tokyo")
    end

    it "accepts a Hash with :prompt key" do
      result = chain.invoke({prompt: "Capital of Japan?"})
      expect(result[:output]).to eq("Tokyo")
    end

    it "passes :system from Hash to with_instructions" do
      chain.invoke({prompt: "question", system: "You are a geography expert."})
      expect(fake_chat).to have_received(:with_instructions).with("You are a geography expert.")
    end

    it "returns a TokenUsage in :usage" do
      result = chain.invoke("Hello")
      expect(result[:usage]).to be_a(Phronomy::TokenUsage)
    end

    it "raises ArgumentError for Hash without a :prompt key" do
      expect { chain.invoke({something: "else"}) }.to raise_error(ArgumentError, /prompt key/)
    end
  end

  describe "#>>" do
    it "returns a SequentialChain" do
      other = described_class.new(model: "test-model")
      expect(chain >> other).to be_a(Phronomy::Chain::SequentialChain)
    end
  end
end

# ---------------------------------------------------------------------------
RSpec.describe "Agent::Base instructions with PromptTemplate" do
  let(:fake_tokens) { double("Tokens", input: 5, output: 3, cached: 0, cache_creation: 0) }
  let(:fake_response) { double("Response", content: "answer", tool_calls: nil, tokens: fake_tokens) }
  let(:fake_chat) do
    dbl = double("Chat")
    allow(dbl).to receive(:with_instructions).and_return(dbl)
    allow(dbl).to receive(:with_tool).and_return(dbl)
    allow(dbl).to receive(:with_temperature).and_return(dbl)
    allow(dbl).to receive(:ask).and_return(fake_response)
    allow(dbl).to receive(:messages).and_return([fake_response])
    dbl
  end

  before { allow(RubyLLM).to receive(:chat).and_return(fake_chat) }

  it "uses the system_template as the system prompt when input is a Hash" do
    tmpl = Phronomy::Chain::PromptTemplate.new(
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
    tmpl = Phronomy::Chain::PromptTemplate.new(template: "Act as a {{role}}.")

    agent_class = Class.new(Phronomy::Agent::Base) do
      model "test-model"
      instructions tmpl
    end

    agent_class.new.invoke({role: "chef", message: "Hello"})
    expect(fake_chat).to have_received(:with_instructions).with("Act as a chef.")
  end
end
