# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::Agent do
  # A minimal stub agent that echoes its input with a prefix.
  class EchoAgent < Phronomy::Agent::Base
    agent_definition id: "echo-agent", version: 1
    model "openai/gpt-4o-mini"
    instructions "You are an echo agent."

    def invoke(input, config: {})
      msg = input.is_a?(Hash) ? input[:message] || input.values.first : input.to_s
      {output: "echo: #{msg}", messages: [], usage: nil}
    end
  end

  # Agent with an explicit module namespace to test name derivation.
  module Nested
    class SummarizerAgent < Phronomy::Agent::Base
      agent_definition id: "summarizer-agent", version: 1
      model "openai/gpt-4o-mini"
      instructions "You summarize text."

      def invoke(input, config: {})
        {output: "summary", messages: [], usage: nil}
      end
    end
  end

  describe ".from_agent" do
    it "raises ArgumentError when agent_class is not a Class" do
      expect { described_class.from_agent("NotAClass") }.to raise_error(ArgumentError, /agent_class must be a Class/)
    end

    it "returns a Class (subclass of Agent)" do
      klass = described_class.from_agent(EchoAgent)
      expect(klass).to be_a(Class)
      expect(klass.ancestors).to include(described_class)
    end

    context "tool_name derivation" do
      it "strips 'Agent' suffix and lowercases the class name" do
        klass = described_class.from_agent(EchoAgent)
        expect(klass.new.name).to eq("echo")
      end

      it "uses the module's last segment for nested agent classes" do
        klass = described_class.from_agent(Nested::SummarizerAgent)
        expect(klass.new.name).to eq("summarizer")
      end

      it "accepts an explicit tool_name override" do
        klass = described_class.from_agent(EchoAgent, tool_name: "my_echo")
        expect(klass.new.name).to eq("my_echo")
      end
    end

    context "description" do
      it "defaults to 'Delegates to <ClassName>'" do
        klass = described_class.from_agent(EchoAgent)
        # RubyLLM::Tool exposes description via the class DSL
        expect(klass.description).to include("EchoAgent")
      end

      it "accepts an explicit description override" do
        klass = described_class.from_agent(EchoAgent, description: "Custom desc")
        expect(klass.description).to eq("Custom desc")
      end
    end

    context "#execute" do
      it "delegates to the wrapped agent and returns its output as a String" do
        klass = described_class.from_agent(EchoAgent)
        result = klass.new.execute(input: "hello")
        expect(result).to eq("echo: hello")
      end

      it "returns a String even when the agent output is nil" do
        klass = described_class.from_agent(EchoAgent)
        allow_any_instance_of(EchoAgent).to receive(:invoke).and_return({output: nil, messages: []})
        result = klass.new.execute(input: "anything")
        expect(result).to eq("")
      end
    end

    it "generates independent classes for different agent classes" do
      klass_a = described_class.from_agent(EchoAgent)
      klass_b = described_class.from_agent(Nested::SummarizerAgent)
      expect(klass_a).not_to eq(klass_b)
      expect(klass_a.new.name).not_to eq(klass_b.new.name)
    end
  end
end
