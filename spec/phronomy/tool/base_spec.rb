# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tool::Base do
  # A simple tool for testing
  let(:hello_tool_class) do
    Class.new(described_class) do
      description "Greeting tool"
      param :name, type: :string, desc: "Name"

      def execute(name:)
        "Hello, #{name}!"
      end
    end
  end

  let(:hello_tool) { hello_tool_class.new }

  describe "DSL" do
    describe ".description" do
      it "sets and retrieves the description" do
        expect(hello_tool_class.description).to eq("Greeting tool")
      end
    end

    describe ".param" do
      it "registers the parameter" do
        expect(hello_tool_class.parameters.keys).to include(:name)
      end
    end

    describe ".scope" do
      it "sets and retrieves the scope" do
        klass = Class.new(described_class) { scope :read_only }
        expect(klass.scope).to eq(:read_only)
      end

      it "returns nil when not set" do
        klass = Class.new(described_class)
        expect(klass.scope).to be_nil
      end
    end

    describe ".on_error" do
      it "defaults to :raise" do
        expect(hello_tool_class.on_error).to eq(:raise)
      end

      it "can be set to :return_empty" do
        klass = Class.new(described_class) { on_error :return_empty }
        expect(klass.on_error).to eq(:return_empty)
      end
    end

    describe ".requires_approval" do
      it "defaults to false" do
        expect(hello_tool_class.requires_approval).to eq(false)
      end

      it "can be set to true" do
        klass = Class.new(described_class) { requires_approval true }
        expect(klass.requires_approval).to eq(true)
      end
    end
  end

  describe "#call" do
    it "returns the result of execute" do
      result = hello_tool.call({"name" => "Ruby"})
      expect(result).to eq("Hello, Ruby!")
    end

    context "when execute raises an error" do
      let(:failing_tool_class) do
        Class.new(described_class) do
          def execute
            raise "something went wrong"
          end
        end
      end
      let(:failing_tool) { failing_tool_class.new }

      context "with on_error :raise (default)" do
        it "raises Phronomy::ToolError" do
          expect { failing_tool.call({}) }.to raise_error(Phronomy::ToolError, /execution failed/)
        end
      end

      context "on_error :return_empty" do
        let(:failing_tool_class) do
          Class.new(described_class) do
            on_error :return_empty

            def execute
              raise "something went wrong"
            end
          end
        end

        it "returns [] without raising an exception" do
          expect(failing_tool.call({})).to eq([])
        end
      end
    end
  end

  describe "#requires_approval?" do
    it "reflects the class setting" do
      klass = Class.new(described_class) { requires_approval true }
      expect(klass.new.requires_approval?).to eq(true)
    end

    it "returns false when not set" do
      expect(hello_tool.requires_approval?).to eq(false)
    end
  end

  describe "RubyLLM::Tool compatibility" do
    it "is a subclass of RubyLLM::Tool" do
      expect(described_class.ancestors).to include(RubyLLM::Tool)
    end

    it "converts the class name to snake_case in the name method" do
      klass = Class.new(described_class)
      # anonymous classes have nil name, so bind to a constant for testing
      stub_const("MySearchTool", klass)
      expect(klass.new.name).to eq("my_search")
    end
  end
end
