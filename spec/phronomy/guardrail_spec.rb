# frozen_string_literal: true

require "spec_helper"

# Guardrail classes have been removed. Blocking filters are now implemented
# directly as Phronomy::Filter::Base subclasses that call block!.
# This file tests the equivalent behaviour via Filter::Base.

RSpec.describe Phronomy::Filter::Base do
  let(:blocking_filter) do
    Class.new(described_class) do
      def call(value, **_ctx)
        block!("rejected") if value.to_s.include?("bad")
        value
      end
    end.new
  end

  describe "#call" do
    it "returns the value unchanged when it passes" do
      expect(blocking_filter.call("good input")).to eq("good input")
    end

    it "raises FilterBlockError when the value is rejected" do
      expect { blocking_filter.call("bad input") }.to raise_error(Phronomy::FilterBlockError, "rejected")
    end

    it "attaches the filter instance to the error" do
      blocking_filter.call("bad input")
    rescue Phronomy::FilterBlockError => e
      expect(e.filter).to be(blocking_filter)
    end
  end

  describe "#call (not overridden)" do
    it "raises NotImplementedError" do
      base = described_class.new
      expect { base.call("anything") }.to raise_error(NotImplementedError)
    end
  end
end

RSpec.describe "Agent::Base blocking filter integration" do
  let(:agent_class) { Class.new(Phronomy::Agent::Base) { agent_definition id: "test-agent-205", version: 1 } }
  let(:agent) { agent_class.new }

  let(:no_bad_input) do
    Class.new(Phronomy::Filter::Base) do
      def call(value, **_ctx)
        block!("input contains 'bad'") if value.to_s.include?("bad")
        value
      end
    end.new
  end

  let(:no_secret_output) do
    Class.new(Phronomy::Filter::Base) do
      def call(value, **_ctx)
        block!("output contains 'SECRET'") if value.to_s.include?("SECRET")
        value
      end
    end.new
  end

  describe "#add_input_filter" do
    it "raises FilterBlockError on invoke when input fails the check" do
      agent.add_input_filter(no_bad_input)
      expect { agent.invoke("bad content") }.to raise_error(Phronomy::FilterBlockError, /bad/)
    end

    it "does not raise when input passes the check" do
      agent.add_input_filter(no_bad_input)
      chat_double = double("Chat")
      response = double("response", content: "ok", tool_call?: false, tokens: double(input: 5, output: 2, cached: 0, cache_creation: 0, to_h: {"input" => 5, "output" => 2, "cached" => 0, "cache_creation" => 0}))
      allow(RubyLLM).to receive(:chat).and_return(chat_double)
      allow(chat_double).to receive(:with_tool).and_return(chat_double)
      allow(chat_double).to receive(:with_instructions).and_return(chat_double)
      allow(chat_double).to receive(:with_temperature).and_return(chat_double)
      allow(chat_double).to receive(:cancellation_token=)
      allow(chat_double).to receive(:on_tool_call)
      allow(chat_double).to receive(:on_tool_result)
      allow(chat_double).to receive(:ask).and_return(response)
      allow(chat_double).to receive(:messages).and_return([])
      expect { agent.invoke("clean content") }.not_to raise_error
    end
  end

  describe "#add_output_filter" do
    it "raises FilterBlockError when output fails the check" do
      agent.add_output_filter(no_secret_output)
      chat_double = double("Chat")
      response = double("response", content: "here is your SECRET key", tool_call?: false, tokens: double(input: 5, output: 10, cached: 0, cache_creation: 0, to_h: {"input" => 5, "output" => 10, "cached" => 0, "cache_creation" => 0}))
      allow(RubyLLM).to receive(:chat).and_return(chat_double)
      allow(chat_double).to receive(:with_tool).and_return(chat_double)
      allow(chat_double).to receive(:with_instructions).and_return(chat_double)
      allow(chat_double).to receive(:with_temperature).and_return(chat_double)
      allow(chat_double).to receive(:cancellation_token=)
      allow(chat_double).to receive(:on_tool_call)
      allow(chat_double).to receive(:on_tool_result)
      allow(chat_double).to receive(:ask).and_return(response)
      allow(chat_double).to receive(:messages).and_return([])
      expect { agent.invoke("tell me the key") }.to raise_error(Phronomy::FilterBlockError, /SECRET/)
    end
  end

  describe "multiple blocking filters" do
    it "runs all input filters in order and raises on the first failure" do
      f1 = Class.new(Phronomy::Filter::Base) do
        def call(v, **_ctx) = v
      end.new
      f2 = Class.new(Phronomy::Filter::Base) do
        def call(v, **_ctx)
          block!("f2 rejected")
        end
      end.new

      agent.add_input_filter(f1)
      agent.add_input_filter(f2)
      expect { agent.invoke("anything") }.to raise_error(Phronomy::FilterBlockError, "f2 rejected")
    end
  end
end
