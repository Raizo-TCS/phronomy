# frozen_string_literal: true

# Contract tests for Phronomy::Agent::Context::Capability::Base implementations (Issue #231).
#
# Usage:
#   it_behaves_like "a tool" do
#     let(:tool) { described_class.new }
#   end
#
# Callers must provide:
#   - `tool` — a fresh tool instance whose execute method returns a String
RSpec.shared_examples "a tool" do
  describe "inheritance" do
    it "is a subclass of Phronomy::Agent::Context::Capability::Base" do
      expect(tool).to be_a(Phronomy::Agent::Context::Capability::Base)
    end
  end

  describe "interface" do
    it "responds to #execute" do
      expect(tool).to respond_to(:execute)
    end

    it "responds to #params_schema" do
      expect(tool).to respond_to(:params_schema)
    end

    it "responds to .description" do
      expect(tool.class).to respond_to(:description)
    end
  end

  describe "#params_schema" do
    subject(:schema) { tool.params_schema }

    it "returns a Hash" do
      expect(schema).to be_a(Hash)
    end

    it "has a 'type' key" do
      expect(schema).to have_key("type")
    end

    it "type is 'object'" do
      expect(schema["type"]).to eq("object")
    end

    it "has a 'properties' key" do
      expect(schema).to have_key("properties")
    end
  end

  describe ".description" do
    it "returns a non-empty String" do
      desc = tool.class.description
      expect(desc).to be_a(String)
      expect(desc).not_to be_empty
    end
  end

  describe "on_error: :suppress" do
    let(:suppressing_tool_class) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "Suppressing tool"
        on_error :suppress

        def execute
          raise "simulated execute failure"
        end
      end
    end

    it "returns a String instead of raising when execute raises" do
      result = suppressing_tool_class.new.call({})
      expect(result).to be_a(String)
    end

    it "does not raise when execute raises" do
      expect { suppressing_tool_class.new.call({}) }.not_to raise_error
    end
  end

  describe "on_error: :raise (default)" do
    let(:raising_tool_class) do
      Class.new(Phronomy::Agent::Context::Capability::Base) do
        description "Raising tool"

        def execute
          raise ArgumentError, "bad input"
        end
      end
    end

    it "wraps the exception as Phronomy::ToolError" do
      expect { raising_tool_class.new.call({}) }.to raise_error(Phronomy::ToolError)
    end
  end
end
