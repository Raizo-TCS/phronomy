# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Guardrail::Base do
  let(:guardrail) do
    Class.new(described_class) do
      def check(value)
        fail!("rejected") if value.to_s.include?("bad")
      end
    end.new
  end

  describe "#run!" do
    it "returns the value unchanged when the check passes" do
      expect(guardrail.run!("good input")).to eq("good input")
    end

    it "raises GuardrailError when the check fails" do
      expect { guardrail.run!("bad input") }.to raise_error(Phronomy::GuardrailError, "rejected")
    end

    it "attaches the guardrail instance to the error" do
      guardrail.run!("bad input")
    rescue Phronomy::GuardrailError => e
      expect(e.guardrail).to be(guardrail)
    end
  end

  describe "#check" do
    it "raises NotImplementedError when not overridden" do
      base = described_class.new
      expect { base.check("anything") }.to raise_error(NotImplementedError)
    end
  end
end

RSpec.describe Phronomy::Guardrail::InputGuardrail do
  it "is a subclass of Guardrail::Base" do
    expect(described_class).to be < Phronomy::Guardrail::Base
  end
end

RSpec.describe Phronomy::Guardrail::OutputGuardrail do
  it "is a subclass of Guardrail::Base" do
    expect(described_class).to be < Phronomy::Guardrail::Base
  end
end

RSpec.describe "Agent::Base guardrail integration" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base)
  end

  let(:agent) { agent_class.new }

  let(:no_bad_input) do
    Class.new(Phronomy::Guardrail::InputGuardrail) do
      def check(input)
        fail!("input contains 'bad'") if input.to_s.include?("bad")
      end
    end.new
  end

  let(:no_secret_output) do
    Class.new(Phronomy::Guardrail::OutputGuardrail) do
      def check(output)
        fail!("output contains 'SECRET'") if output.to_s.include?("SECRET")
      end
    end.new
  end

  describe "#add_input_guardrail" do
    it "returns self for chaining" do
      expect(agent.add_input_guardrail(no_bad_input)).to be(agent)
    end

    it "raises GuardrailError on invoke when input fails the check" do
      agent.add_input_guardrail(no_bad_input)
      expect { agent.invoke("bad content") }.to raise_error(Phronomy::GuardrailError, /bad/)
    end

    it "does not raise when input passes the check" do
      agent.add_input_guardrail(no_bad_input)
      chat_double = instance_double(RubyLLM::Chat)
      response = double("response", content: "ok")
      allow(RubyLLM).to receive(:chat).and_return(chat_double)
      allow(chat_double).to receive(:with_tool)
      allow(chat_double).to receive(:with_instructions)
      allow(chat_double).to receive(:ask).and_return(response)
      allow(chat_double).to receive(:messages).and_return([])
      expect { agent.invoke("clean content") }.not_to raise_error
    end
  end

  describe "#add_output_guardrail" do
    it "returns self for chaining" do
      expect(agent.add_output_guardrail(no_secret_output)).to be(agent)
    end

    it "raises GuardrailError when output fails the check" do
      agent.add_output_guardrail(no_secret_output)
      chat_double = instance_double(RubyLLM::Chat)
      response = double("response", content: "here is your SECRET key")
      allow(RubyLLM).to receive(:chat).and_return(chat_double)
      allow(chat_double).to receive(:with_tool)
      allow(chat_double).to receive(:with_instructions)
      allow(chat_double).to receive(:ask).and_return(response)
      allow(chat_double).to receive(:messages).and_return([])
      expect { agent.invoke("tell me the key") }.to raise_error(Phronomy::GuardrailError, /SECRET/)
    end
  end

  describe "multiple guardrails" do
    it "runs all input guardrails in order and raises on the first failure" do
      g1 = Class.new(Phronomy::Guardrail::InputGuardrail) do
        def check(v)
        end
      end.new
      g2 = Class.new(Phronomy::Guardrail::InputGuardrail) do
        def check(v)
          fail!("g2 rejected")
        end
      end.new

      agent.add_input_guardrail(g1)
      agent.add_input_guardrail(g2)
      expect { agent.invoke("anything") }.to raise_error(Phronomy::GuardrailError, "g2 rejected")
    end
  end
end
