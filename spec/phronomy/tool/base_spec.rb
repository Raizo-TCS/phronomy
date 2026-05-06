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

  describe "multiple parameters" do
    let(:multi_param_tool_class) do
      Class.new(described_class) do
        description "Multi-param tool"
        param :city,    type: :string,  desc: "City name"
        param :country, type: :string,  desc: "Country code"
        param :limit,   type: :integer, desc: "Result limit", required: false

        def execute(city:, country:, limit: 10)
          "#{city}, #{country} (limit: #{limit})"
        end
      end
    end

    it "registers all parameters" do
      expect(multi_param_tool_class.parameters.keys).to contain_exactly(:city, :country, :limit)
    end

    it "includes all parameters in params_schema" do
      properties = multi_param_tool_class.new.params_schema["properties"]
      expect(properties.keys).to contain_exactly("city", "country", "limit")
    end

    it "passes all required arguments to execute" do
      result = multi_param_tool_class.new.call({ "city" => "Tokyo", "country" => "JP" })
      expect(result).to eq("Tokyo, JP (limit: 10)")
    end

    it "passes all arguments including optional ones to execute" do
      result = multi_param_tool_class.new.call({ "city" => "Paris", "country" => "FR", "limit" => "5" })
      expect(result).to eq("Paris, FR (limit: 5)")
    end
  end

  describe ".param with enum:" do
    let(:enum_tool_class) do
      Class.new(described_class) do
        description "Search tool with enum param"
        param :query, type: :string, desc: "Search query"
        param :lang,  type: :string, desc: "Language code", required: false,
                      enum: %w[en ja fr]

        def execute(query:, lang: "en")
          "#{query} (#{lang})"
        end
      end
    end

    it "stores enum values on the class" do
      expect(enum_tool_class.param_enums[:lang]).to eq(%w[en ja fr])
    end

    it "does not store enum for params without enum:" do
      expect(enum_tool_class.param_enums[:query]).to be_nil
    end

    describe "#params_schema" do
      subject(:schema) { enum_tool_class.new.params_schema }

      it "includes enum in the schema for the constrained param" do
        properties = schema["properties"]
        expect(properties["lang"]["enum"]).to eq(%w[en ja fr])
      end

      it "does not add enum to params without enum:" do
        properties = schema["properties"]
        expect(properties["query"]).not_to have_key("enum")
      end
    end

    it "accepts valid enum values at call time" do
      result = enum_tool_class.new.call({ "query" => "hello", "lang" => "ja" })
      expect(result).to eq("hello (ja)")
    end
  end

  describe ".param_enums with no enum declarations" do
    it "returns an empty hash" do
      klass = Class.new(described_class) do
        param :input, type: :string, desc: "input"
      end
      expect(klass.param_enums).to eq({})
    end

    it "does not modify params_schema" do
      klass = Class.new(described_class) do
        param :input, type: :string, desc: "input"
        def execute(input:) = input
      end
      schema = klass.new.params_schema
      expect(schema["properties"]["input"]).not_to have_key("enum")
    end
  end

  describe ".tool_name DSL" do
    context "when tool_name is set" do
      let(:named_tool_class) do
        Class.new(described_class) do
          tool_name "weather_search"
          description "Search weather"
          param :city, type: :string, desc: "City"

          def execute(city:) = "weather for #{city}"
        end
      end

      it "stores the explicit name on the class" do
        expect(named_tool_class.tool_name).to eq("weather_search")
      end

      it "#name returns the explicit tool_name" do
        expect(named_tool_class.new.name).to eq("weather_search")
      end

      it "accepts a Symbol and coerces to String" do
        klass = Class.new(described_class) { tool_name :my_tool }
        expect(klass.tool_name).to eq("my_tool")
      end
    end

    context "when tool_name is not set" do
      it "returns nil from the class method" do
        klass = Class.new(described_class)
        expect(klass.tool_name).to be_nil
      end

      it "#name falls back to RubyLLM automatic conversion" do
        klass = Class.new(described_class)
        stub_const("WeatherSearchTool", klass)
        expect(klass.new.name).to eq("weather_search")
      end
    end

    context "when two classes share an auto-generated name" do
      it "can be disambiguated with tool_name" do
        weather_klass = Class.new(described_class) do
          tool_name "weather_search"
          def execute = "weather"
        end
        places_klass = Class.new(described_class) do
          tool_name "places_search"
          def execute = "places"
        end
        expect(weather_klass.new.name).to eq("weather_search")
        expect(places_klass.new.name).to eq("places_search")
        expect(weather_klass.new.name).not_to eq(places_klass.new.name)
      end
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
