# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tools::Agent do
  # A minimal stub Agent that echoes its input with a prefix.
  class EchoAgent < Phronomy::Agent::Base
    agent_definition id: "echo-agent", version: 1
    model "openai/gpt-4o-mini"
    instructions "You are an echo agent."

    def invoke(input, config: {}, **_options)
      msg = input.is_a?(Hash) ? input[:message] || input.values.first : input.to_s
      {output: "echo: #{msg}", messages: [], usage: nil}
    end

    def invoke_async(input, config: {}, **options)
      task = Phronomy::Task.deferred(name: "echo-agent")
      task.complete(invoke(input, config: config, **options))
      task
    rescue => error
      task ||= Phronomy::Task.deferred(name: "echo-agent")
      task.fail(error)
      task
    end
  end

  # Agent with an explicit module namespace to test name derivation.
  module Nested
    class SummarizerAgent < Phronomy::Agent::Base
      agent_definition id: "summarizer-agent", version: 1
      model "openai/gpt-4o-mini"
      instructions "You summarize text."

      def invoke(input, config: {}, **_options)
        {output: "summary", messages: [], usage: nil}
      end

      def invoke_async(input, config: {}, **options)
        task = Phronomy::Task.deferred(name: "summarizer-agent")
        task.complete(invoke(input, config: config, **options))
        task
      end
    end
  end

  describe ".from_agent" do
    it "raises ArgumentError when agent_class is not a Class" do
      expect { described_class.from_agent("NotAClass") }
        .to raise_error(ArgumentError, /agent_class must be a Class/)
    end

    it "returns a Class (subclass of Agent)" do
      klass = described_class.from_agent(EchoAgent)
      expect(klass).to be_a(Class)
      expect(klass.ancestors).to include(described_class)
    end

    it "uses the cooperative execution contract" do
      klass = described_class.from_agent(EchoAgent)
      expect(klass.execution_mode).to eq(:cooperative)
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
        expect(klass.description).to include("EchoAgent")
      end

      it "accepts an explicit description override" do
        klass = described_class.from_agent(EchoAgent, description: "Custom desc")
        expect(klass.description).to eq("Custom desc")
      end
    end

    context "#execute" do
      it "delegates synchronously to the wrapped Agent and returns a String" do
        klass = described_class.from_agent(EchoAgent)
        result = klass.new.execute(input: "hello")
        expect(result).to eq("echo: hello")
      end

      it "returns a String even when the Agent output is nil" do
        klass = described_class.from_agent(EchoAgent)
        allow_any_instance_of(EchoAgent).to receive(:invoke).and_return({output: nil, messages: []})
        result = klass.new.execute(input: "anything")
        expect(result).to eq("")
      end
    end

    context "#call_async" do
      it "preserves Agent-owned Tool result filters on the custom async path" do
        tool_class = described_class.from_agent(EchoAgent)
        filter = Class.new(Phronomy::Filter::Base) do
          def call(value, **_context)
            "#{value}|filtered"
          end
        end.new
        parent_class = Class.new(Phronomy::Agent::Base) do
          agent_definition id: "agent-tool-filter-parent", version: 1
          model "test"
          tools tool_class => nil
        end
        parent = parent_class.new
        parent.add_tool_result_filter(tool_class, filter)
        prepared = parent.send(:prepare_tool_class, tool_class)

        result = prepared.new.call_async({"input" => "hello"}).wait_result

        expect(result).to eq("echo: hello|filtered")
      end

      it "starts the child Agent asynchronously without ToolExecutor/OffloadPool" do
        klass = described_class.from_agent(EchoAgent)
        allow(Phronomy::Agent::ToolExecutor).to receive(:call_async).and_call_original

        task = klass.new.call_async({"input" => "hello"})

        expect(task).to be_a(Phronomy::Task)
        expect(task.wait_result).to eq("echo: hello")
        expect(Phronomy::Agent::ToolExecutor).not_to have_received(:call_async)
      end

      it "returns an empty String for a nil asynchronous Agent output" do
        klass = described_class.from_agent(EchoAgent)
        allow_any_instance_of(EchoAgent).to receive(:invoke_async) do
          Phronomy::Task.deferred(name: "nil-output").tap do |task|
            task.complete({output: nil, messages: []})
          end
        end

        expect(klass.new.call_async({"input" => "anything"}).wait_result).to eq("")
      end
    end

    it "generates independent classes for different Agent classes" do
      klass_a = described_class.from_agent(EchoAgent)
      klass_b = described_class.from_agent(Nested::SummarizerAgent)
      expect(klass_a).not_to eq(klass_b)
      expect(klass_a.new.name).not_to eq(klass_b.new.name)
    end
  end
end
