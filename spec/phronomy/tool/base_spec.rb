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

  it_behaves_like "a tool" do
    let(:tool) { hello_tool }
  end

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

      it "can be set to :return_empty (deprecated alias)" do
        expect { Class.new(described_class) { on_error :return_empty } }
          .to output(/deprecated.*suppress/i).to_stderr
      end

      it "can be set to :suppress (new canonical name, issue #165)" do
        klass = Class.new(described_class) { on_error :suppress }
        expect(klass.on_error).to eq(:suppress)
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

        it "returns a descriptive error string without raising an exception (Issue #147)" do
          expect(failing_tool.call({})).to match(/Tool error suppressed:.*went wrong/)
        end

        it "does not raise an exception" do
          expect { failing_tool.call({}) }.not_to raise_error
        end
      end

      context "on_error :suppress (canonical name, issue #165)" do
        let(:failing_tool_class) do
          Class.new(described_class) do
            on_error :suppress

            def execute
              raise "something went wrong"
            end
          end
        end

        it "returns a descriptive error string without raising an exception" do
          expect(failing_tool.call({})).to match(/Tool error suppressed:.*went wrong/)
        end

        it "does not raise an exception" do
          expect { failing_tool.call({}) }.not_to raise_error
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
        param :city, type: :string, desc: "City name"
        param :country, type: :string, desc: "Country code"
        param :limit, type: :integer, desc: "Result limit", required: false

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
      result = multi_param_tool_class.new.call({"city" => "Tokyo", "country" => "JP"})
      expect(result).to eq("Tokyo, JP (limit: 10)")
    end

    it "passes all arguments including optional ones to execute" do
      result = multi_param_tool_class.new.call({"city" => "Paris", "country" => "FR", "limit" => 5})
      expect(result).to eq("Paris, FR (limit: 5)")
    end
  end

  describe ".param with enum:" do
    let(:enum_tool_class) do
      Class.new(described_class) do
        description "Search tool with enum param"
        param :query, type: :string, desc: "Search query"
        param :lang, type: :string, desc: "Language code", required: false,
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
      result = enum_tool_class.new.call({"query" => "hello", "lang" => "ja"})
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

  # Regression tests for Issue #48: params_schema always converts enum values to String
  # via .map(&:to_s), even for :integer and :number params.  The JSON Schema spec
  # requires enum values to match the declared type.
  describe ".param with enum: and non-string types (Issue #48)" do
    context "with an integer param and integer enum values" do
      let(:int_enum_tool_class) do
        Class.new(described_class) do
          description "Priority tool"
          param :level, type: :integer, desc: "Priority level", enum: [1, 2, 3]

          def execute(level:) = "priority: #{level}"
        end
      end

      it "preserves Integer type in JSON Schema enum values" do
        schema = int_enum_tool_class.new.params_schema
        enum_vals = schema["properties"]["level"]["enum"]
        expect(enum_vals).to all(be_a(Integer))
      end

      it "does not convert integer enum values to String" do
        schema = int_enum_tool_class.new.params_schema
        enum_vals = schema["properties"]["level"]["enum"]
        expect(enum_vals).not_to include("1", "2", "3")
      end

      it "produces a conforming JSON Schema (integer type with integer enum)" do
        schema = int_enum_tool_class.new.params_schema
        prop = schema["properties"]["level"]
        expect(prop["type"]).to eq("integer")
        expect(prop["enum"]).to eq([1, 2, 3])
      end
    end

    context "with a number param and float enum values" do
      let(:float_enum_tool_class) do
        Class.new(described_class) do
          description "Temperature tool"
          param :temp, type: :number, desc: "Temperature", enum: [0.0, 0.5, 1.0]

          def execute(temp:) = "temp: #{temp}"
        end
      end

      it "preserves Numeric type in JSON Schema enum values" do
        schema = float_enum_tool_class.new.params_schema
        enum_vals = schema["properties"]["temp"]["enum"]
        expect(enum_vals).to all(be_a(Numeric))
      end

      it "does not convert float enum values to String" do
        schema = float_enum_tool_class.new.params_schema
        enum_vals = schema["properties"]["temp"]["enum"]
        expect(enum_vals).not_to include("0.0", "0.5", "1.0")
      end
    end

    context "with a string param and enum values (existing behaviour should be unchanged)" do
      let(:str_enum_tool_class) do
        Class.new(described_class) do
          description "Lang tool"
          param :lang, type: :string, desc: "Language", enum: %w[en ja fr]

          def execute(lang:) = lang
        end
      end

      it "keeps String type for string enum values" do
        schema = str_enum_tool_class.new.params_schema
        enum_vals = schema["properties"]["lang"]["enum"]
        expect(enum_vals).to all(be_a(String))
        expect(enum_vals).to eq(%w[en ja fr])
      end
    end

    context "with an :object param and nested properties (issue #162)" do
      let(:nested_tool_class) do
        Class.new(described_class) do
          description "Config tool"
          param :config, type: :object, desc: "Configuration", properties: {
            timeout: {type: :integer, desc: "Timeout in seconds"},
            retries: {type: :integer, desc: "Retry count"}
          }

          def execute(config:) = "config: #{config}"
        end
      end

      it "includes 'properties' in the JSON Schema for the object param" do
        schema = nested_tool_class.new.params_schema
        config_schema = schema["properties"]["config"]
        expect(config_schema).to have_key("properties")
      end

      it "includes each nested field in the JSON Schema" do
        schema = nested_tool_class.new.params_schema
        nested = schema["properties"]["config"]["properties"]
        expect(nested.keys).to contain_exactly("timeout", "retries")
      end

      it "includes type and description for each nested field" do
        schema = nested_tool_class.new.params_schema
        timeout_schema = schema["properties"]["config"]["properties"]["timeout"]
        expect(timeout_schema["type"]).to eq("integer")
        expect(timeout_schema["description"]).to eq("Timeout in seconds")
      end
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

  describe "required parameter validation (S14)" do
    let(:required_param_tool) do
      Class.new(described_class) do
        description "Weather tool"
        param :city, type: :string, desc: "City name"

        def execute(city:) = "Weather in #{city}"
      end.new
    end

    it "returns a descriptive schema error including the param name when required param is missing" do
      result = required_param_tool.call({})
      expect(result).to include("required parameter 'city' is missing")
    end

    it "does not raise ArgumentError for a missing required param" do
      expect { required_param_tool.call({}) }.not_to raise_error
    end
  end

  describe "coerce_mode error handling (S02)" do
    let(:coerce_tool) do
      Class.new(described_class) do
        description "Coerce tool"
        on_schema_error :coerce
        param :count, type: :integer, desc: "Count"

        def execute(count:) = "count: #{count}"
      end.new
    end

    it "returns a schema error message when coercion fails" do
      result = coerce_tool.call({"count" => "not-a-number"})
      expect(result).to include("Schema validation failed")
    end
  end

  # Regression for Finding 5 — :return_error mode silently accepts string integers
  # (Issue #<tbd>): When on_schema_error is :return_error (default), passing "42"
  # for an :integer parameter passes type_error? validation because the regex
  # /\A-?\d+\z/ matches, but the value is stored as a String and forwarded to
  # execute unchanged.  The execute method therefore receives "42" (String) instead
  # of 42 (Integer), which may cause unexpected behaviour in typed operations.
  describe "return_error mode type coercion (Finding 5)" do
    let(:int_tool) do
      Class.new(described_class) do
        description "Integer tool"
        # default: on_schema_error :return_error
        param :count, type: :integer, desc: "Count"

        def execute(count:)
          # Return the Ruby class of the received value so the spec can assert it.
          count.class.name
        end
      end.new
    end

    # This spec will FAIL until Finding 5 is fixed.
    # Expected: passing "42" for an :integer param under :return_error mode should
    # either (a) return a schema error or (b) coerce to Integer.
    # Current (buggy) behaviour: "42" passes validation and execute receives String.
    it "does not silently pass a string '42' as a valid :integer in :return_error mode" do
      result = int_tool.call({"count" => "42"})
      # After the fix, this should either be a schema error string OR return "Integer".
      # Currently it returns "String", which is wrong.
      expect(result).not_to eq("String"),
        "execute received a String instead of Integer — :return_error mode must reject '42' or coerce it"
    end
  end

  describe "unknown parameter rejection (issue #130)" do
    let(:simple_tool) do
      Class.new(described_class) do
        description "A simple tool"
        param :name, type: :string, desc: "Name"

        def execute(name:)
          "hello #{name}"
        end
      end.new
    end

    it "returns a schema-error string when an unknown key is passed (default :return_error mode)" do
      result = simple_tool.call({"name" => "Alice", "injected" => "evil"})
      expect(result).to start_with("Schema validation failed:")
      expect(result).to include("injected")
    end

    it "does not pass unknown keys through to execute" do
      executed_args = nil
      tool = Class.new(described_class) do
        description "spy tool"
        param :x, type: :string, desc: "x"

        define_method(:execute) do |**kwargs|
          executed_args = kwargs
          "ok"
        end
      end.new

      tool.call({"x" => "v", "secret" => "payload"})
      expect(executed_args).to be_nil.or(satisfy { |a| !a.key?(:secret) })
    end

    it "raises ToolError when on_schema_error is :raise and unknown key is given" do
      strict_tool = Class.new(described_class) do
        description "strict"
        on_schema_error :raise
        param :n, type: :string, desc: "n"

        def execute(n:)
          n
        end
      end.new

      expect { strict_tool.call({"n" => "ok", "bad" => "x"}) }
        .to raise_error(Phronomy::ToolError, /unknown parameter/)
    end
  end

  describe "nested schema validation (Issue #131)" do
    let(:nested_tool_class) do
      Class.new(described_class) do
        description "nested tool"
        on_schema_error :return_error
        param :config, type: :object, desc: "config",
          properties: {
            timeout: {type: :integer, required: true},
            retry: {type: :boolean, required: false}
          }

        def execute(config:)
          "ok: #{config.inspect}"
        end
      end
    end

    it "passes when nested required field is present with correct type" do
      result = nested_tool_class.new.call({"config" => {"timeout" => 5, "retry" => true}})
      expect(result).to match(/^ok:/)
      expect(result).to include("5")
    end

    it "returns error when nested required field is missing (Issue #131)" do
      result = nested_tool_class.new.call({"config" => {"retry" => false}})
      expect(result).to match(/nested required field.*config\.timeout.*missing/i)
    end

    it "returns error when nested field has wrong type (Issue #131)" do
      result = nested_tool_class.new.call({"config" => {"timeout" => "not-an-int"}})
      expect(result).to match(/nested field.*config\.timeout/i)
    end

    it "raises ToolError when on_schema_error is :raise and nested type is wrong (Issue #131)" do
      strict_nested = Class.new(described_class) do
        description "strict nested"
        on_schema_error :raise
        param :opts, type: :object, desc: "opts",
          properties: {count: {type: :integer, required: true}}

        def execute(opts:)
          "ok"
        end
      end.new

      expect { strict_nested.call({"opts" => {"count" => "bad"}}) }
        .to raise_error(Phronomy::ToolError, /nested field.*opts\.count/i)
    end

    it "validates deeply nested properties recursively (Issue #131)" do
      deep_tool = Class.new(described_class) do
        description "deep nested tool"
        on_schema_error :return_error
        param :root, type: :object, desc: "root",
          properties: {
            child: {
              type: :object, required: true,
              properties: {
                leaf: {type: :string, required: true}
              }
            }
          }

        def execute(root:)
          "ok"
        end
      end.new

      result = deep_tool.call({"root" => {"child" => {"leaf" => 42}}})
      expect(result).to match(/nested field.*root\.child\.leaf/i)
    end

    it "rejects extra keys inside a nested object (issue #166)" do
      tool = Class.new(described_class) do
        description "options tool"
        on_schema_error :return_error
        param :options, type: :object, properties: {
          timeout: {type: :integer}
        }

        def execute(options:) = options.inspect
      end.new

      result = tool.call({"options" => {"timeout" => 5, "injected" => "payload"}})
      expect(result).to match(/undeclared key/i)
    end
  end

  describe "cancellation_token injection (#234)" do
    let(:token_receiving_class) do
      Class.new(described_class) do
        description "token-aware tool"
        param :msg, type: :string, desc: "message"

        def execute(msg:, cancellation_token: nil)
          "#{msg}:#{cancellation_token.class}"
        end
      end
    end

    let(:token_unaware_class) do
      Class.new(described_class) do
        description "plain tool"
        param :msg, type: :string, desc: "message"

        def execute(msg:)
          "plain:#{msg}"
        end
      end
    end

    it "injects Thread.current[:phronomy_cancellation_token] when execute accepts it" do
      token = Phronomy::CancellationToken.new
      Thread.current[:phronomy_cancellation_token] = token
      result = token_receiving_class.new.call({"msg" => "hi"})
      expect(result).to eq("hi:Phronomy::CancellationToken")
    ensure
      Thread.current[:phronomy_cancellation_token] = nil
    end

    it "does not inject when no token is set in Thread.current" do
      Thread.current[:phronomy_cancellation_token] = nil
      result = token_receiving_class.new.call({"msg" => "hi"})
      expect(result).to eq("hi:NilClass")
    end

    it "does not inject when execute does not accept cancellation_token:" do
      token = Phronomy::CancellationToken.new
      Thread.current[:phronomy_cancellation_token] = token
      result = token_unaware_class.new.call({"msg" => "plain"})
      expect(result).to eq("plain:plain")
    ensure
      Thread.current[:phronomy_cancellation_token] = nil
    end

    it "raises CancellationError when token is cancelled and tool calls raise_if_cancelled!" do
      token = Phronomy::CancellationToken.new
      token.cancel!
      Thread.current[:phronomy_cancellation_token] = token

      checking_class = Class.new(described_class) do
        description "check tool"
        param :msg, type: :string, desc: "message"

        def execute(msg:, cancellation_token: nil)
          cancellation_token&.raise_if_cancelled!
          "should not reach"
        end
      end

      expect { checking_class.new.call({"msg" => "x"}) }.to raise_error(Phronomy::CancellationError)
    ensure
      Thread.current[:phronomy_cancellation_token] = nil
    end
  end
end
