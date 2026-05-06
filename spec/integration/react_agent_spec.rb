# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "ReactAgent integration", :integration do
  # A simple tool that can be called by the agent
  let(:calculator_class) do
    Class.new(Phronomy::Tool::Base) do
      description "Calculates the sum of two integers"
      param :a, type: :integer, desc: "First integer"
      param :b, type: :integer, desc: "Second integer"

      def execute(a:, b:)
        a + b
      end
    end
  end

  let(:agent_class) do
    tools = [calculator_class]
    Class.new(Phronomy::Agent::ReactAgent) do
      instructions "You are a calculator assistant. Use the available tool to compute answers."
      @tools = tools
    end
  end

  describe "#invoke" do
    it "returns a Hash with :output and :messages keys" do
      result = agent_class.new.invoke("What is 3 plus 4?")
      expect(result).to be_a(Hash)
      expect(result).to have_key(:output)
      expect(result).to have_key(:messages)
      expect(result[:output]).to be_a(String)
      expect(result[:output]).not_to be_empty
    end
  end
end
