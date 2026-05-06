# frozen_string_literal: true

require_relative "spec_helper"

# A minimal agent for memory integration tests.
class MemoryTestAgent < Phronomy::Agent::Base
  instructions "You are a helpful assistant with a good memory."
end

RSpec.describe "Agent memory integration", :integration do
  # ---- Agent::Base with WindowMemory ----------------------------------------

  describe "Agent::Base with WindowMemory" do
    let(:memory) { Phronomy::Memory::WindowMemory.new(k: 10) }

    it "maintains conversation context across two invocations" do
      agent = MemoryTestAgent.new

      agent.invoke(
        "My name is Alice. Just say 'Got it.'",
        config: { thread_id: "mem-t1", memory: memory }
      )

      result = agent.invoke(
        "What is my name? Reply with only the name.",
        config: { thread_id: "mem-t1", memory: memory }
      )

      expect(result[:output].downcase).to include("alice")
    end

    it "does NOT recall context when no memory is given" do
      agent = MemoryTestAgent.new

      # First turn without memory — name is stated but not persisted
      agent.invoke("My name is Bob. Just say 'Got it.'")

      # Second turn — new agent, no memory, should not know the name
      result = agent.invoke(
        "Reply with only: YES if you know my name, NO if you don't."
      )

      expect(result[:output].upcase).to include("NO")
    end

    it "keeps separate context per thread_id" do
      agent = MemoryTestAgent.new

      agent.invoke(
        "My favourite colour is red. Just say 'Got it.'",
        config: { thread_id: "mem-colour-a", memory: memory }
      )
      agent.invoke(
        "My favourite colour is blue. Just say 'Got it.'",
        config: { thread_id: "mem-colour-b", memory: memory }
      )

      result_a = agent.invoke(
        "What is my favourite colour? Reply with only the colour name.",
        config: { thread_id: "mem-colour-a", memory: memory }
      )
      result_b = agent.invoke(
        "What is my favourite colour? Reply with only the colour name.",
        config: { thread_id: "mem-colour-b", memory: memory }
      )

      expect(result_a[:output].downcase).to include("red")
      expect(result_b[:output].downcase).to include("blue")
    end
  end

  # ---- ReactAgent with WindowMemory -----------------------------------------

  describe "ReactAgent with WindowMemory" do
    let(:memory) { Phronomy::Memory::WindowMemory.new(k: 10) }

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
        instructions "You are a helpful assistant. Use tools when needed."
        @tools = tools
      end
    end

    it "remembers the result of a previous tool call in a follow-up question" do
      agent = agent_class.new

      agent.invoke(
        "What is 10 plus 5? Use the calculator tool.",
        config: { thread_id: "react-mem-t1", memory: memory }
      )

      result = agent.invoke(
        "What was the result of the calculation you just did? Reply with only the number.",
        config: { thread_id: "react-mem-t1", memory: memory }
      )

      expect(result[:output]).to include("15")
    end
  end
end
