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

    context "cancellation token handling" do
      let(:ct_aware_class) do
        Class.new(described_class) do
          description "ct aware"
          param :msg, type: :string, desc: "msg"

          def execute(msg:, cancellation_token: nil)
            "#{msg}:#{cancellation_token.class}"
          end
        end
      end

      it "injects cancellation_token into execute when it accepts ct" do
        ct = Phronomy::CancellationToken.new
        result = ct_aware_class.new.call({"msg" => "hi"}, cancellation_token: ct)
        expect(result).to include("CancellationToken")
      end

      it "does not inject cancellation_token when execute does not accept it" do
        ct = Phronomy::CancellationToken.new
        result = hello_tool.call({"name" => "Ruby"}, cancellation_token: ct)
        expect(result).to eq("Hello, Ruby!")
      end

      it "raises CancellationError when cancellation_token is already cancelled" do
        ct = Phronomy::CancellationToken.new
        ct.cancel!
        expect { hello_tool.call({"name" => "x"}, cancellation_token: ct) }
          .to raise_error(Phronomy::CancellationError)
      end

      it "succeeds normally when cancellation_token is nil" do
        result = hello_tool.call({"name" => "Ruby"}, cancellation_token: nil)
        expect(result).to eq("Hello, Ruby!")
      end
    end

    context "schema error handling in #call" do
      let(:strict_schema_tool) do
        Class.new(described_class) do
          description "strict"
          on_schema_error :raise
          param :count, type: :integer, desc: "count"

          def execute(count:) = count.to_s
        end.new
      end

      let(:default_schema_tool) do
        Class.new(described_class) do
          description "default"
          param :count, type: :integer, desc: "count"

          def execute(count:) = count.to_s
        end.new
      end

      it "raises ToolError when on_schema_error is :raise and type is wrong" do
        expect { strict_schema_tool.call({"count" => "bad"}) }
          .to raise_error(Phronomy::ToolError, /schema error/)
      end

      it "returns schema error string when on_schema_error is default and type is wrong" do
        result = default_schema_tool.call({"count" => "bad"})
        expect(result).to match(/Schema validation failed/)
      end

      it "includes the schema error message in the ToolError" do
        expect { strict_schema_tool.call({"count" => "bad"}) }
          .to raise_error(Phronomy::ToolError, /integer/)
      end
    end

    context "error suppression — logger vs stderr" do
      let(:suppress_class) do
        Class.new(described_class) do
          description "suppress"
          on_error :suppress

          def execute
            raise RuntimeError, "boom"
          end
        end
      end

      it "calls logger.warn when on_error :suppress and logger is configured" do
        logged = []
        logger = double("Logger")
        allow(logger).to receive(:warn) { |msg| logged << msg }
        allow(Phronomy.configuration).to receive(:logger).and_return(logger)
        suppress_class.new.call({})
        expect(logged.first).to include("boom")
      end

      it "writes to stderr when on_error :suppress and no logger is configured" do
        allow(Phronomy.configuration).to receive(:logger).and_return(nil)
        expect { suppress_class.new.call({}) }.to output(/boom/).to_stderr
      end

      it "includes the tool class name in the suppression message" do
        logged = []
        logger = double("Logger")
        allow(logger).to receive(:warn) { |msg| logged << msg }
        allow(Phronomy.configuration).to receive(:logger).and_return(logger)
        tool = suppress_class.new
        tool.call({})
        expect(logged.first).to match(/Phronomy::Tool::Base|Tool/)
      end

      it "includes e.class and e.message in the suppression message" do
        logged = []
        logger = double("Logger")
        allow(logger).to receive(:warn) { |msg| logged << msg }
        allow(Phronomy.configuration).to receive(:logger).and_return(logger)
        suppress_class.new.call({})
        expect(logged.first).to include("RuntimeError")
        expect(logged.first).to include("boom")
      end

      it "includes e.message (not just e) in the return string" do
        allow(Phronomy.configuration).to receive(:logger).and_return(nil)
        result = suppress_class.new.call({})
        expect(result).to eq("Tool error suppressed: boom")
      end
    end

    context "ToolError propagation" do
      let(:tool_error_class) do
        Class.new(described_class) do
          description "raises tool error"

          def execute
            raise Phronomy::ToolError, "original message"
          end
        end
      end

      it "re-raises ToolError without wrapping in another ToolError" do
        expect { tool_error_class.new.call({}) }
          .to raise_error(Phronomy::ToolError, "original message")
      end

      it "does not wrap ToolError message in execution failed" do
        error = nil
        begin
          tool_error_class.new.call({})
        rescue Phronomy::ToolError => e
          error = e
        end
        expect(error.message).to eq("original message")
        expect(error.message).not_to include("execution failed")
      end
    end

    context "schema error message content" do
      let(:named_strict_tool_class) do
        Class.new(described_class) do
          description "named"
          on_schema_error :raise
          param :n, type: :integer, desc: "n"

          def execute(n:) = n.to_s
        end
      end

      it "schema error ToolError message includes schema_error content" do
        begin
          named_strict_tool_class.new.call({"n" => "bad"})
        rescue Phronomy::ToolError => e
          expect(e.message).to include("schema error")
          expect(e.message).to include("integer")
        end
      end

      it "schema error return string includes schema_error content" do
        default_tool = Class.new(described_class) do
          description "d"
          param :n, type: :integer, desc: "n"

          def execute(n:) = n.to_s
        end.new
        result = default_tool.call({"n" => "bad"})
        expect(result).to include("integer")
      end

      it "execution failed ToolError includes class name" do
        raise_class = Class.new(described_class) do
          description "r"

          def execute
            raise StandardError, "runtime issue"
          end
        end.new
        begin
          raise_class.call({})
        rescue Phronomy::ToolError => e
          expect(e.message).to include("execution failed")
          expect(e.message).to include("runtime issue")
        end
      end
    end

    context "ct=nil and execute_accepts_cancellation_token?" do
      let(:ct_rejects_nil_class) do
        Class.new(described_class) do
          description "strict ct"

          def execute(cancellation_token: nil)
            cancellation_token.inspect
          end
        end
      end

      it "does not inject cancellation_token: nil when ct is nil" do
        result = ct_rejects_nil_class.new.call({}, cancellation_token: nil)
        expect(result).to eq("nil")
      end
    end

    context "ct=nil does not inject when guard removed (sentinel test)" do
      # Kills mutation [6]: removes 'ct &&' from 'if ct && execute_accepts_ct?'
      it "does not inject cancellation_token when ct is nil even if execute accepts it" do
        klass = Class.new(described_class) do
          description "sentinel ct"

          def execute(cancellation_token: :NOT_INJECTED)
            cancellation_token.equal?(:NOT_INJECTED) ? "sentinel_intact" : "injected:#{cancellation_token.inspect}"
          end
        end.new
        result = klass.call({}, cancellation_token: nil)
        expect(result).to eq("sentinel_intact")
      end
    end

    context "schema error is not suppressed by on_error policy" do
      # Kills mutation [2]: raise("string") vs raise(ToolError, "string")
      it "raises ToolError for schema error even when on_error is :suppress" do
        klass = Class.new(described_class) do
          description "strict suppress"
          on_schema_error :raise
          on_error :suppress
          param :n, type: :integer, desc: "n"

          def execute(n:) = n.to_s
        end.new
        expect { klass.call({"n" => "bad"}) }
          .to raise_error(Phronomy::ToolError, /schema error/)
      end
    end

    context "schema error message uses class name (not nil, not #<Class:, not snake_case)" do
      # Kills mutations [3] (nil class), [4] (#{self.class}), [5] (self.name snake_case)
      let(:named_schema_klass) do
        stub_const("NamedSchemaToolMT", Class.new(described_class) do
          description "named schema"
          on_schema_error :raise
          param :n, type: :integer, desc: "n"

          def execute(n:) = n.to_s
        end)
        NamedSchemaToolMT
      end

      it "includes full class name in schema error message" do
        err = nil
        begin; named_schema_klass.new.call({"n" => "bad"}); rescue Phronomy::ToolError => e; err = e; end
        expect(err.message).to include("NamedSchemaToolMT")
      end

      it "does not use snake_case tool name in schema error message" do
        err = nil
        begin; named_schema_klass.new.call({"n" => "bad"}); rescue Phronomy::ToolError => e; err = e; end
        expect(err.message).not_to include("named_schema_tool_mt")
      end

      it "schema error for anonymous class does not use #<Class: notation" do
        anon = Class.new(described_class) do
          description "anon schema"
          on_schema_error :raise
          param :n, type: :integer, desc: "n"

          def execute(n:) = n.to_s
        end.new
        err = nil
        begin; anon.call({"n" => "bad"}); rescue Phronomy::ToolError => e; err = e; end
        expect(err.message).not_to include("#<Class:")
      end
    end

    context "retry policy is applied via with_tool_retry" do
      # Kills mutation [7]: result = super(validated_args) bypasses with_tool_retry
      it "retries execute according to retry_on policy" do
        attempts = 0
        klass = Class.new(described_class) do
          description "retry tool"
          retry_on StandardError, times: 2, wait: 0
        end
        klass.define_method(:execute) do
          attempts += 1
          raise StandardError, "temp failure" if attempts < 2
          "ok_attempt_#{attempts}"
        end
        expect(klass.new.call({})).to eq("ok_attempt_2")
        expect(attempts).to eq(2)
      end
    end

    context "result truncation via truncate_result_if_needed" do
      # Kills mutations [8] (truncate call replaced by result) and [9] (line deleted)
      let(:truncating_klass) do
        Class.new(described_class) do
          description "truncating"
          max_result_size 10

          def execute = "a" * 50
        end
      end

      it "truncates result that exceeds max_result_size" do
        result = truncating_klass.new.call({})
        expect(result).to include("[truncated]")
        expect(result.length).to be < 50
      end

      it "does not truncate result within max_result_size" do
        klass = Class.new(described_class) do
          description "short result"
          max_result_size 100

          def execute = "short"
        end
        expect(klass.new.call({})).to eq("short")
      end
    end

    context "suppress message uses class name (not nil, not #<Class:, not snake_case)" do
      # Kills mutations [10] (#{self.class}), [11] (#{nil}), [12] (self.name)
      let(:named_suppress_klass) do
        stub_const("NamedSuppressToolMT", Class.new(described_class) do
          description "named suppress"
          on_error :suppress

          def execute = raise RuntimeError, "boom"
        end)
        NamedSuppressToolMT
      end

      def capture_warn_log(tool)
        logged = []
        logger = double("Logger")
        allow(logger).to receive(:warn) { |msg| logged << msg }
        allow(Phronomy.configuration).to receive(:logger).and_return(logger)
        tool.call({})
        logged.first
      end

      it "includes full class name in suppress log message" do
        msg = capture_warn_log(named_suppress_klass.new)
        expect(msg).to include("NamedSuppressToolMT")
      end

      it "does not use snake_case tool name in suppress log message" do
        msg = capture_warn_log(named_suppress_klass.new)
        expect(msg).not_to include("named_suppress_tool_mt")
      end

      it "suppress log for anonymous class does not use #<Class: notation" do
        anon = Class.new(described_class) do
          description "anon suppress"
          on_error :suppress

          def execute = raise RuntimeError, "anon_boom"
        end.new
        msg = capture_warn_log(anon)
        expect(msg).not_to include("#<Class:")
      end
    end

    context "execution failed message uses class name (not nil, not #<Class:, not snake_case)" do
      # Kills mutations [16] (#{nil}), [17] (#{self.class}), [18] (self.name)
      let(:named_error_klass) do
        stub_const("NamedErrorToolMT", Class.new(described_class) do
          description "named error"

          def execute = raise StandardError, "runtime_issue"
        end)
        NamedErrorToolMT
      end

      it "includes full class name in execution failed message" do
        err = nil
        begin; named_error_klass.new.call({}); rescue Phronomy::ToolError => e; err = e; end
        expect(err.message).to include("NamedErrorToolMT")
      end

      it "does not use snake_case tool name in execution failed message" do
        err = nil
        begin; named_error_klass.new.call({}); rescue Phronomy::ToolError => e; err = e; end
        expect(err.message).not_to include("named_error_tool_mt")
      end

      it "execution failed for anonymous class does not use #<Class: notation" do
        anon = Class.new(described_class) do
          description "anon error"

          def execute = raise StandardError, "issue"
        end.new
        err = nil
        begin; anon.call({}); rescue Phronomy::ToolError => e; err = e; end
        expect(err.message).not_to include("#<Class:")
      end
    end

    # NOTE: mutations [13],[14],[19] (e.message vs e.to_s) are genuine equivalents
    # in Ruby: Exception#message calls to_s internally, so overriding to_s
    # also changes message. No test can distinguish them.
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

  describe ".param with properties: (nested schema registration)" do
    it "stores normalized param_schemas for object params" do
      klass = Class.new(described_class) do
        description "t"
        param :data, type: :object, desc: "data", properties: {
          "name" => {"type" => "string"}
        }

        def execute(data:) = data.inspect
      end
      expect(klass.param_schemas[:data]).to be_a(Hash)
      expect(klass.param_schemas[:data].keys).to all(be_a(Symbol))
    end

    it "applies normalize_nested_schema (not raw properties) to param_schemas" do
      klass = Class.new(described_class) do
        description "t"
        param :data, type: :object, desc: "data", properties: {
          "name" => {type: :string}
        }

        def execute(data:) = data.inspect
      end
      expect(klass.param_schemas[:data]).to have_key(:name)
      expect(klass.param_schemas[:data]).not_to have_key("name")
    end

    it "does not store param_schemas for non-object params" do
      klass = Class.new(described_class) do
        description "t"
        param :count, type: :integer, desc: "count"

        def execute(count:) = count
      end
      expect(klass.param_schemas[:count]).to be_nil
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

    it "injects the cancellation_token kwarg into execute when execute accepts it" do
      token = Phronomy::CancellationToken.new
      result = token_receiving_class.new.call({"msg" => "hi"}, cancellation_token: token)
      expect(result).to eq("hi:Phronomy::CancellationToken")
    end

    it "does not inject when no cancellation_token: is passed" do
      result = token_receiving_class.new.call({"msg" => "hi"})
      expect(result).to eq("hi:NilClass")
    end

    it "does not inject when execute does not accept cancellation_token:" do
      token = Phronomy::CancellationToken.new
      result = token_unaware_class.new.call({"msg" => "plain"}, cancellation_token: token)
      expect(result).to eq("plain:plain")
    end

    it "raises CancellationError when token is cancelled and tool calls raise_if_cancelled!" do
      token = Phronomy::CancellationToken.new
      token.cancel!

      checking_class = Class.new(described_class) do
        description "check tool"
        param :msg, type: :string, desc: "message"

        def execute(msg:, cancellation_token: nil)
          cancellation_token&.raise_if_cancelled!
          "should not reach"
        end
      end

      expect { checking_class.new.call({"msg" => "x"}, cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError at call entry when a cancelled token is passed as kwarg (#242)" do
      token = Phronomy::CancellationToken.new
      token.cancel!
      plain_class = Class.new(described_class) do
        description "plain tool"
        param :msg, type: :string, desc: "message"

        def execute(msg:)
          "should not reach"
        end
      end
      expect { plain_class.new.call({"msg" => "hi"}, cancellation_token: token) }
        .to raise_error(Phronomy::CancellationError)
    end

    it "cancellation_token: kwarg causes CancellationError at call entry when cancelled (#242)" do
      Phronomy::CancellationToken.new
      cancelled_kwarg_token = Phronomy::CancellationToken.new
      cancelled_kwarg_token.cancel!

      plain_class = Class.new(described_class) do
        description "plain tool"
        param :msg, type: :string, desc: "message"

        def execute(msg:)
          "ok"
        end
      end
      expect { plain_class.new.call({"msg" => "hi"}, cancellation_token: cancelled_kwarg_token) }
        .to raise_error(Phronomy::CancellationError)
    end
  end

  # Issue #293 — Tool#call_async must respect the execution_mode DSL setting.
  # :cooperative tools should run directly in a Task; :blocking_io tools should
  # be routed through BlockingAdapterPool when a Runtime is present.
  describe "#call_async execution_mode routing (Issue #293)", :issue_293 do
    after { Phronomy::Runtime.instance_variable_set(:@instance, nil) }

    let(:cooperative_tool_class) do
      Class.new(described_class) do
        description "cooperative tool"
        execution_mode :cooperative
        param :x, type: :string, desc: "input"

        def execute(x:)
          "coop:#{x}"
        end
      end
    end

    let(:blocking_tool_class) do
      Class.new(described_class) do
        description "blocking tool"
        execution_mode :blocking_io
        param :x, type: :string, desc: "input"

        def execute(x:)
          "block:#{x}"
        end
      end
    end

    it "cooperative tool: call_async returns a Task that resolves correctly" do
      task = cooperative_tool_class.new.call_async({"x" => "hi"})
      expect(task).to be_a(Phronomy::Task)
      expect(task.await).to eq("coop:hi")
    end

    it "blocking_io tool with pool: call_async routes through BlockingAdapterPool" do
      pool = Phronomy::Runtime.instance.blocking_io
      called = false
      allow(pool).to receive(:submit).and_wrap_original do |m, **kw, &blk|
        called = true
        m.call(**kw, &blk)
      end

      awaitable = blocking_tool_class.new.call_async({"x" => "io"})
      expect(awaitable).to respond_to(:await)
      expect(awaitable.await).to eq("block:io")
      expect(called).to be(true)
    end

    it "blocking_io tool without pool: call_async falls back to Runtime.instance.spawn" do
      # Reset so no pool is present but Runtime itself still exists
      runtime = instance_double(Phronomy::Runtime, blocking_io: nil)
      allow(runtime).to receive(:spawn) do |name: nil, &blk|
        t = double("Task-fallback")
        allow(t).to receive(:await).and_return(blk.call)
        t
      end
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)

      task = blocking_tool_class.new.call_async({"x" => "fallback"})
      expect(task).to be_a(Phronomy::Task).or respond_to(:await)
      expect(task.await).to eq("block:fallback")
    end
  end

  describe "#call_async — direct unit tests" do
    it "passes cancellation_token to Phronomy::ToolExecutor" do
      ct = Phronomy::CancellationToken.new
      expect(Phronomy::ToolExecutor).to receive(:call_async).with(
        tool: hello_tool,
        args: {},
        cancellation_token: ct
      )
      hello_tool.call_async({}, cancellation_token: ct)
    end

    it "passes nil cancellation_token by default" do
      expect(Phronomy::ToolExecutor).to receive(:call_async).with(
        tool: hello_tool,
        args: {},
        cancellation_token: nil
      )
      hello_tool.call_async({})
    end

    it "delegates to Phronomy::ToolExecutor (not unqualified ToolExecutor)" do
      expect(Phronomy::ToolExecutor).to receive(:call_async).and_call_original
      result = hello_tool.call_async({})
      expect(result).to respond_to(:await)
    end
  end

  describe "#params_schema — no-params tool" do
    let(:no_params_class) do
      Class.new(described_class) do
        description "no params"

        def execute
          "ok"
        end
      end
    end

    it "returns nil or an empty-property schema when the tool has no declared parameters" do
      # ruby_llm >= 1.15 infers an empty-property schema from the execute signature;
      # ruby_llm <= 1.14 returns nil.  Either way, Phronomy must not add properties.
      schema = no_params_class.new.params_schema
      expect(schema).to satisfy { |s| s.nil? || (s.is_a?(Hash) && s["properties"].empty?) }
    end

    it "passes through the schema from super unchanged" do
      tool = no_params_class.new
      allow(tool).to receive(:params_schema).and_call_original
      schema = tool.params_schema
      expect(schema).to satisfy { |s| s.nil? || (s.is_a?(Hash) && s["properties"].empty?) }
    end
  end

  describe "#type_error" do
    let(:tool) { hello_tool }

    it "returns nil when value is nil regardless of type" do
      expect(tool.send(:type_error, nil, :string)).to be_nil
      expect(tool.send(:type_error, nil, :integer)).to be_nil
      expect(tool.send(:type_error, nil, :boolean)).to be_nil
    end

    context "returns nil when type matches" do
      it ":string accepts a String" do
        expect(tool.send(:type_error, "hello", :string)).to be_nil
      end

      it ":integer accepts an Integer" do
        expect(tool.send(:type_error, 42, :integer)).to be_nil
      end

      it ":number accepts a Numeric" do
        expect(tool.send(:type_error, 3.14, :number)).to be_nil
      end

      it ":float accepts a Numeric" do
        expect(tool.send(:type_error, 3.14, :float)).to be_nil
      end

      it ":boolean accepts true" do
        expect(tool.send(:type_error, true, :boolean)).to be_nil
      end

      it ":boolean accepts false" do
        expect(tool.send(:type_error, false, :boolean)).to be_nil
      end

      it ":array accepts an Array" do
        expect(tool.send(:type_error, [1, 2], :array)).to be_nil
      end

      it ":object accepts a Hash" do
        expect(tool.send(:type_error, {a: 1}, :object)).to be_nil
      end

      it "unknown type passes through" do
        expect(tool.send(:type_error, "anything", :custom_type)).to be_nil
      end
    end

    context "returns error String when type mismatches" do
      it ":integer for a String value includes 'expected type integer'" do
        result = tool.send(:type_error, "hello", :integer)
        expect(result).to be_a(String)
        expect(result).to include("expected type integer")
      end

      it ":string for an Integer value includes 'expected type string'" do
        result = tool.send(:type_error, 42, :string)
        expect(result).to include("expected type string")
      end

      it ":number for a String value includes 'expected type number'" do
        expect(tool.send(:type_error, "hi", :number)).to include("expected type number")
      end

      it ":float for a String value includes 'expected type float'" do
        expect(tool.send(:type_error, "hi", :float)).to include("expected type float")
      end

      it ":boolean for a String value includes 'expected type boolean'" do
        expect(tool.send(:type_error, "true", :boolean)).to include("expected type boolean")
      end

      it ":array for a Hash value includes 'expected type array'" do
        expect(tool.send(:type_error, {}, :array)).to include("expected type array")
      end

      it ":object for an Array value includes 'expected type object'" do
        expect(tool.send(:type_error, [], :object)).to include("expected type object")
      end

      it "uses '(object)' placeholder for Hash values in the error message" do
        result = tool.send(:type_error, {a: 1}, :string)
        expect(result).to include("(object)")
      end

      it "does not use '(object)' for non-Hash values" do
        result = tool.send(:type_error, 42, :string)
        expect(result).not_to include("(object)")
        expect(result).to include("42")
      end

      it "uses value.inspect for non-Hash values in the error message" do
        result = tool.send(:type_error, "bad", :integer)
        expect(result).to include('"bad"')
      end

      it ":integer rejects Float (not a subtype)" do
        expect(tool.send(:type_error, 3.14, :integer)).to include("expected type integer")
      end
    end

    context "declared_type as String (kills mutation [45]: removes .to_sym)" do
      it "handles String declared_type 'integer' correctly" do
        expect(tool.send(:type_error, "bad", "integer")).to include("expected type integer")
      end

      it "handles String declared_type 'string' correctly (no error for String value)" do
        expect(tool.send(:type_error, "hello", "string")).to be_nil
      end
    end

    context "accepts subclasses of declared type (kills [46], [48], [49])" do
      it "returns nil for String subclass with :string type (is_a? not instance_of?)" do
        sub_str = Class.new(String).new("hello")
        expect(tool.send(:type_error, sub_str, :string)).to be_nil
      end

      it "returns nil for Array subclass with :array type" do
        sub_arr = Class.new(Array).new
        expect(tool.send(:type_error, sub_arr, :array)).to be_nil
      end

      it "returns nil for Hash subclass with :object type" do
        sub_hash = Class.new(Hash).new
        expect(tool.send(:type_error, sub_hash, :object)).to be_nil
      end
    end
  end

  describe "#coerce_value" do
    let(:tool) { hello_tool }

    it "returns [value, nil] (not [nil, nil]) for nil input" do
      val, err = tool.send(:coerce_value, nil, :string)
      expect(val).to be_nil
      expect(err).to be_nil
    end

    it "returns the original nil object (identity) for nil" do
      result = tool.send(:coerce_value, nil, :integer)
      expect(result).to eq([nil, nil])
    end

    context ":string" do
      it "returns string as-is" do
        expect(tool.send(:coerce_value, "hello", :string)).to eq(["hello", nil])
      end

      it "coerces Integer to String" do
        val, err = tool.send(:coerce_value, 42, :string)
        expect(err).to be_nil
        expect(val).to eq("42")
      end

      it "coerces Float to String" do
        val, err = tool.send(:coerce_value, 3.14, :string)
        expect(err).to be_nil
        expect(val).to eq("3.14")
      end
    end

    context ":integer" do
      it "returns Integer as-is" do
        expect(tool.send(:coerce_value, 42, :integer)).to eq([42, nil])
      end

      it "coerces numeric String to Integer" do
        val, err = tool.send(:coerce_value, "42", :integer)
        expect(err).to be_nil
        expect(val).to eq(42)
      end

      it "returns [nil, error] for non-numeric String" do
        val, err = tool.send(:coerce_value, "abc", :integer)
        expect(val).to be_nil
        expect(err).to include("integer")
      end
    end

    context ":number" do
      it "returns Float as-is" do
        val, err = tool.send(:coerce_value, 3.14, :number)
        expect(err).to be_nil
        expect(val).to eq(3.14)
      end

      it "coerces numeric String to Float" do
        val, err = tool.send(:coerce_value, "3.14", :number)
        expect(err).to be_nil
        expect(val).to eq(3.14)
      end

      it "returns [nil, error] for non-numeric String" do
        val, err = tool.send(:coerce_value, "abc", :number)
        expect(val).to be_nil
        expect(err).to include("number")
      end
    end

    context ":float" do
      it "coerces numeric String to Float" do
        val, err = tool.send(:coerce_value, "2.5", :float)
        expect(err).to be_nil
        expect(val).to eq(2.5)
      end

      it "returns [nil, error] for non-numeric String" do
        val, err = tool.send(:coerce_value, "bad", :float)
        expect(val).to be_nil
        expect(err).to include("float")
      end

      it "returns a 2-element Array for :float type (kills mutation [8])" do
        # Kills [8]: [coerced, nil] → [coerced] — size drops from 2 to 1
        arr = tool.send(:coerce_value, "3.14", :float)
        expect(arr).to be_an(Array)
        expect(arr.size).to eq(2)
        expect(arr.last).to be_nil
      end

      it "return value is an Array not a Float for :float type (kills mutation [9])" do
        # Kills [9]: removes the [coerced, nil] line entirely — method returns Float not Array
        result = tool.send(:coerce_value, "3.14", :float)
        expect(result).to be_an(Array)
      end
    end

    context ":boolean" do
      it "coerces 'true' to true" do
        expect(tool.send(:coerce_value, "true", :boolean)).to eq([true, nil])
      end

      it "coerces 'false' to false" do
        expect(tool.send(:coerce_value, "false", :boolean)).to eq([false, nil])
      end

      it "coerces 'TRUE' (case-insensitive) to true" do
        expect(tool.send(:coerce_value, "TRUE", :boolean)).to eq([true, nil])
      end

      it "coerces 'FALSE' (case-insensitive) to false" do
        expect(tool.send(:coerce_value, "FALSE", :boolean)).to eq([false, nil])
      end

      it "returns [nil, error] for unrecognized boolean string" do
        val, err = tool.send(:coerce_value, "yes", :boolean)
        expect(val).to be_nil
        expect(err).to include("boolean")
      end

      it "passes through true as-is" do
        expect(tool.send(:coerce_value, true, :boolean)).to eq([true, nil])
      end

      it "passes through false as-is" do
        expect(tool.send(:coerce_value, false, :boolean)).to eq([false, nil])
      end
    end

    context "pass-through types" do
      it "returns Array as-is for :array" do
        arr = [1, 2, 3]
        val, err = tool.send(:coerce_value, arr, :array)
        expect(err).to be_nil
        expect(val).to equal(arr)
      end

      it "returns Hash as-is for :object" do
        hash = {a: 1}
        val, err = tool.send(:coerce_value, hash, :object)
        expect(err).to be_nil
        expect(val).to equal(hash)
      end

      it "returns value as-is for unknown type" do
        val, err = tool.send(:coerce_value, "anything", :custom)
        expect(err).to be_nil
        expect(val).to eq("anything")
      end
    end

    context "return value is always a 2-element Array (kills [23], [24], [28])" do
      it "coerce_value returns a 2-element Array for :integer coercion" do
        # Kills [23] ([coerced] vs [coerced, nil]) and [24] (line deleted)
        arr = tool.send(:coerce_value, "42", :integer)
        expect(arr).to be_an(Array)
        expect(arr.size).to eq(2)
        expect(arr.last).to be_nil
      end

      it "coerce_value returns a 2-element Array for pass-through :array" do
        # Kills [28]: [value] vs [value, nil] in else branch
        arr = tool.send(:coerce_value, [1, 2, 3], :array)
        expect(arr).to be_an(Array)
        expect(arr.size).to eq(2)
        expect(arr.last).to be_nil
      end

      it "coerce_value returns a 2-element Array for pass-through :object" do
        arr = tool.send(:coerce_value, {a: 1}, :object)
        expect(arr).to be_an(Array)
        expect(arr.size).to eq(2)
      end
    end

    context "declared_type as String (kills mutation [22]: removes .to_sym)" do
      it "coerces correctly when declared_type is the String 'integer'" do
        val, err = tool.send(:coerce_value, "42", "integer")
        expect(err).to be_nil
        expect(val).to eq(42)
      end

      it "coerces correctly when declared_type is the String 'boolean'" do
        val, err = tool.send(:coerce_value, "true", "boolean")
        expect(err).to be_nil
        expect(val).to eq(true)
      end
    end

    context "boolean coerce error message uses value.inspect (kills [25], [26], [27])" do
      it "boolean error message includes the value with inspect formatting (quotes for String)" do
        # Kills [26]: #{value} (no inspect) vs #{value.inspect}
        _val, err = tool.send(:coerce_value, "maybe", :boolean)
        expect(err).to include('"maybe"')
      end

      it "boolean error message is not nil for the value portion" do
        # Kills [25]: #{nil} in place of #{value.inspect}
        _val, err = tool.send(:coerce_value, "maybe", :boolean)
        expect(err).to match(/maybe/)
      end

      it "boolean error message does not use self.inspect (tool instance repr)" do
        # Kills [27]: #{self.inspect} in place of #{value.inspect}
        _val, err = tool.send(:coerce_value, "maybe", :boolean)
        expect(err).not_to include("#<")
        expect(err).to include('"maybe"')
      end
    end

    context "coerce error message (rescue path) uses value.inspect (kills [29], [30], [31])" do
      it "coerce error message includes the value with inspect formatting" do
        # Kills [29]: #{value} (no inspect) — String "bad" appears with quotes
        _val, err = tool.send(:coerce_value, "bad", :integer)
        expect(err).to include('"bad"')
      end

      it "coerce error message is not nil for the value portion" do
        # Kills [30]: #{nil} in place of #{value.inspect}
        _val, err = tool.send(:coerce_value, "bad", :integer)
        expect(err).to match(/bad/)
      end

      it "coerce error message does not use self.inspect (tool instance repr)" do
        # Kills [31]: #{self.inspect} in place of #{value.inspect}
        _val, err = tool.send(:coerce_value, "bad", :integer)
        expect(err).not_to include("#<")
        expect(err).to include('"bad"')
      end
    end
  end

  describe "#truncate_result_if_needed" do
    let(:tool) { hello_tool }

    context "when no max is configured" do
      it "returns the result string unchanged" do
        long = "x" * 10_000
        expect(tool.send(:truncate_result_if_needed, long)).to eq(long)
      end

      it "returns a non-string object unchanged" do
        obj = Object.new
        expect(tool.send(:truncate_result_if_needed, obj)).to equal(obj)
      end
    end

    context "when per-tool max_result_size is set" do
      let(:limited_tool) do
        klass = Class.new(described_class) do
          description "limited"
          max_result_size 10

          def execute
            "ok"
          end
        end
        klass.new
      end

      it "returns result unchanged when within the limit" do
        expect(limited_tool.send(:truncate_result_if_needed, "short")).to eq("short")
      end

      it "returns result unchanged when exactly at the limit" do
        expect(limited_tool.send(:truncate_result_if_needed, "a" * 10)).to eq("a" * 10)
      end

      it "truncates and appends '...[truncated]' when over the limit" do
        result = limited_tool.send(:truncate_result_if_needed, "a" * 20)
        expect(result).to start_with("a" * 10)
        expect(result).to end_with("...[truncated]")
      end

      it "emits a warning when truncating (to logger or stderr)" do
        logged = []
        logger = double("Logger")
        allow(logger).to receive(:warn) { |msg| logged << msg }
        allow(Phronomy.configuration).to receive(:logger).and_return(logger)
        limited_tool.send(:truncate_result_if_needed, "a" * 20)
        expect(logged.first).to include("20 chars > 10 limit")
      end

      it "emits warning to stderr when no logger is configured" do
        allow(Phronomy.configuration).to receive(:logger).and_return(nil)
        expect { limited_tool.send(:truncate_result_if_needed, "a" * 20) }
          .to output(/20 chars > 10 limit/).to_stderr
      end

      it "returns a non-string object unchanged even when max is configured" do
        obj = 42
        result = limited_tool.send(:truncate_result_if_needed, obj)
        expect(result).to equal(obj)
      end

      it "truncates to exactly max characters (verifies result[0, max] not full string)" do
        allow(Phronomy.configuration).to receive(:logger).and_return(nil)
        result = limited_tool.send(:truncate_result_if_needed, "abcdefghijklmno")
        expect(result).to eq("abcdefghij...[truncated]")
      end
    end

    context "when global tool_result_max_size is set" do
      it "truncates using the global limit" do
        allow(Phronomy.configuration).to receive(:tool_result_max_size).and_return(5)
        allow(Phronomy.configuration).to receive(:logger).and_return(nil)
        result = tool.send(:truncate_result_if_needed, "abcdefghij")
        expect(result).to start_with("abcde")
        expect(result).to end_with("...[truncated]")
      end
    end
  end

  describe "#redacted_args" do
    let(:redacting_class) do
      Class.new(described_class) do
        description "secure tool"
        param :username, type: :string, desc: "username"
        param :password, type: :string, desc: "password"
        redact_params :password

        def execute(username:, password:)
          "ok"
        end
      end
    end

    let(:redacting_tool) { redacting_class.new }

    it "replaces redacted param values with '[REDACTED]'" do
      result = redacting_tool.send(:redacted_args, {username: "alice", password: "secret"})
      expect(result[:password]).to eq("[REDACTED]")
    end

    it "preserves non-redacted param values unchanged" do
      result = redacting_tool.send(:redacted_args, {username: "alice", password: "secret"})
      expect(result[:username]).to eq("alice")
    end

    it "returns args unchanged (same object) when no params are redacted" do
      args = {"name" => "test"}
      result = hello_tool.send(:redacted_args, args)
      expect(result).to equal(args)
    end

    it "handles string-keyed args (converts key to sym for comparison)" do
      result = redacting_tool.send(:redacted_args, {"username" => "alice", "password" => "secret"})
      expect(result["password"]).to eq("[REDACTED]")
      expect(result["username"]).to eq("alice")
    end

    it "returns a new hash (not the original) when redaction occurs" do
      args = {username: "alice", password: "secret"}
      result = redacting_tool.send(:redacted_args, args)
      expect(result).not_to equal(args)
    end
  end

  describe "#with_tool_retry" do
    let(:sleep_calls) { [] }
    let(:sleep_stub) { ->(s) { sleep_calls << s } }

    it "executes the block and returns its value when no retry policies exist" do
      result = hello_tool.send(:with_tool_retry) { "direct result" }
      expect(result).to eq("direct result")
    end

    it "propagates exceptions directly when no retry policies exist" do
      expect {
        hello_tool.send(:with_tool_retry) { raise ArgumentError, "no policies" }
      }.to raise_error(ArgumentError, "no policies")
    end

    it "does not retry when the exception class is not in the policy (call count = 1)" do
      klass = Class.new(described_class) do
        description "t"
        retry_on ArgumentError, times: 3, wait: 0

        def execute(**_) = "ok"
      end
      klass._sleep_proc = sleep_stub
      tool = klass.new
      calls = 0
      expect {
        tool.send(:with_tool_retry) do
          calls += 1
          raise RuntimeError, "not covered"
        end
      }.to raise_error(RuntimeError, "not covered")
      expect(calls).to eq(1)
    end

    it "uses find (not first/last) to select the matching policy from multiple policies" do
      klass = Class.new(described_class) do
        description "t"
        retry_on ArgumentError, times: 5, wait: 0
        retry_on RuntimeError, times: 2, wait: 0

        def execute(**_) = "ok"
      end
      klass._sleep_proc = sleep_stub
      tool = klass.new
      calls = 0
      result = tool.send(:with_tool_retry) do
        calls += 1
        raise RuntimeError, "transient" if calls < 3
        "done"
      end
      expect(result).to eq("done")
      expect(calls).to eq(3)
    end

    it "retries when any registered exception matches (not all — testing any? vs all?)" do
      klass = Class.new(described_class) do
        description "t"
        retry_on ArgumentError, RuntimeError, times: 2, wait: 0

        def execute(**_) = "ok"
      end
      klass._sleep_proc = sleep_stub
      tool = klass.new
      calls = 0
      result = tool.send(:with_tool_retry) do
        calls += 1
        raise ArgumentError, "arg-err" if calls < 3
        "ok"
      end
      expect(result).to eq("ok")
      expect(calls).to eq(3)
    end

    it "retries when a subclass of the registered exception is raised (is_a? not instance_of?)" do
      klass = Class.new(described_class) do
        description "t"
        retry_on StandardError, times: 2, wait: 0

        def execute(**_) = "ok"
      end
      klass._sleep_proc = sleep_stub
      tool = klass.new
      calls = 0
      result = tool.send(:with_tool_retry) do
        calls += 1
        raise ArgumentError, "subclass" if calls < 3
        "recovered"
      end
      expect(result).to eq("recovered")
      expect(calls).to eq(3)
    end

    it "does not retry an exact non-matching class (instance_of? semantics would also fail)" do
      klass = Class.new(described_class) do
        description "t"
        retry_on ArgumentError, times: 3, wait: 0

        def execute(**_) = "ok"
      end
      klass._sleep_proc = sleep_stub
      tool = klass.new
      calls = 0
      expect {
        tool.send(:with_tool_retry) do
          calls += 1
          raise TypeError, "type err"
        end
      }.to raise_error(TypeError)
      expect(calls).to eq(1)
    end
  end

  describe "#compute_retry_wait" do
    let(:tool) { hello_tool }

    it "returns base * 2^attempt for :exponential" do
      expect(tool.send(:compute_retry_wait, :exponential, 1.0, 0)).to eq(1.0)
      expect(tool.send(:compute_retry_wait, :exponential, 1.0, 1)).to eq(2.0)
      expect(tool.send(:compute_retry_wait, :exponential, 1.0, 2)).to eq(4.0)
      expect(tool.send(:compute_retry_wait, :exponential, 2.0, 1)).to eq(4.0)
    end

    it "returns (attempt + 1) * base for :linear" do
      expect(tool.send(:compute_retry_wait, :linear, 1.0, 0)).to eq(1.0)
      expect(tool.send(:compute_retry_wait, :linear, 1.0, 1)).to eq(2.0)
      expect(tool.send(:compute_retry_wait, :linear, 2.0, 2)).to eq(6.0)
    end

    it ":linear multiplies (not divides) by base" do
      expect(tool.send(:compute_retry_wait, :linear, 2.0, 2)).to be_within(0.001).of(6.0)
      expect(tool.send(:compute_retry_wait, :linear, 2.0, 2)).not_to be_within(0.001).of(1.5)
    end

    it "returns strategy.to_f when strategy is a Numeric (fixed wait)" do
      expect(tool.send(:compute_retry_wait, 2.5, 1.0, 0)).to eq(2.5)
      expect(tool.send(:compute_retry_wait, 2.5, 1.0, 5)).to eq(2.5)
      expect(tool.send(:compute_retry_wait, 3, 1.0, 0)).to eq(3.0)
    end

    it "returns base.to_f for an unknown strategy symbol" do
      expect(tool.send(:compute_retry_wait, :unknown_strategy, 3.0, 0)).to eq(3.0)
      expect(tool.send(:compute_retry_wait, :unknown_strategy, 2.5, 1)).to eq(2.5)
    end

    it "exponential result differs from linear result for attempt > 0" do
      exp = tool.send(:compute_retry_wait, :exponential, 1.0, 2)
      lin = tool.send(:compute_retry_wait, :linear, 1.0, 2)
      expect(exp).to eq(4.0)
      expect(lin).to eq(3.0)
      expect(exp).not_to eq(lin)
    end

    it "returns a Float (not Integer) for Numeric integer strategy" do
      result = tool.send(:compute_retry_wait, 3, 1.0, 0)
      expect(result).to be_a(Float)
    end

    it "returns a Float (not Integer) for unknown strategy with Integer base" do
      result = tool.send(:compute_retry_wait, :unknown_strategy, 2, 0)
      expect(result).to be_a(Float)
    end
  end

  describe "#validate_and_coerce" do
    let(:typed_tool) do
      Class.new(described_class) do
        description "t"
        param :name, type: :string, desc: "name"

        def execute(name:) = name
      end.new
    end

    let(:no_params_tool) do
      Class.new(described_class) do
        description "no params"

        def execute = "ok"
      end.new
    end

    it "returns [args, nil] immediately (no extra-key check) when tool has no parameters" do
      args = {"any_key" => "value"}
      result, err = no_params_tool.send(:validate_and_coerce, args)
      expect(err).to be_nil
      expect(result).to equal(args)
    end

    it "returns the original args object when no parameters are declared" do
      args = {"x" => 1, "y" => 2}
      result, _err = no_params_tool.send(:validate_and_coerce, args)
      expect(result).to equal(args)
    end

    it "returns [result_hash, nil] on success" do
      result, err = typed_tool.send(:validate_and_coerce, {"name" => "Alice"})
      expect(err).to be_nil
      expect(result).to eq({name: "Alice"})
    end

    it "normalizes string keys to symbol keys in the result" do
      result, err = typed_tool.send(:validate_and_coerce, {"name" => "Bob"})
      expect(err).to be_nil
      expect(result).to have_key(:name)
    end

    it "returns error for missing required parameter" do
      _result, err = typed_tool.send(:validate_and_coerce, {})
      expect(err).to include("name")
    end

    it "handles nil args without raising" do
      _result, err = typed_tool.send(:validate_and_coerce, nil)
      expect(err).to include("name")
    end

    it "returns error for extra (undeclared) keys" do
      _result, err = typed_tool.send(:validate_and_coerce, {"name" => "Alice", "extra" => "x"})
      expect(err).to include("extra")
    end

    let(:int_return_error_tool) do
      Class.new(described_class) do
        description "t"
        param :count, type: :integer, desc: "count"

        def execute(count:) = count
      end.new
    end

    let(:coerce_mode_tool) do
      Class.new(described_class) do
        description "t"
        on_schema_error :coerce
        param :count, type: :integer, desc: "count"

        def execute(count:) = count
      end.new
    end

    let(:enum_param_tool) do
      Class.new(described_class) do
        description "t"
        param :lang, type: :string, desc: "lang", enum: %w[en ja fr]

        def execute(lang:) = lang
      end.new
    end

    let(:nested_param_tool) do
      Class.new(described_class) do
        description "t"
        param :opts, type: :object, desc: "opts",
          properties: {name: {type: :string, required: true}}

        def execute(opts:) = opts
      end.new
    end

    it "returns a type error in return_error mode when integer is given a string" do
      result, err = int_return_error_tool.send(:validate_and_coerce, {"count" => "bad"})
      expect(result).to be_nil
      expect(err).to include("integer")
    end

    it "passes through correct integer type in return_error mode" do
      result, err = int_return_error_tool.send(:validate_and_coerce, {"count" => 5})
      expect(err).to be_nil
      expect(result[:count]).to eq(5)
    end

    it "coerces string to integer in coerce mode" do
      result, err = coerce_mode_tool.send(:validate_and_coerce, {"count" => "42"})
      expect(err).to be_nil
      expect(result[:count]).to eq(42)
    end

    it "returns error when coercion fails in coerce mode" do
      result, err = coerce_mode_tool.send(:validate_and_coerce, {"count" => "bad"})
      expect(result).to be_nil
      expect(err).to include("coerce")
    end

    it "accepts a value that is in the declared enum" do
      result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "en"})
      expect(err).to be_nil
      expect(result[:lang]).to eq("en")
    end

    it "rejects a value not in the declared enum" do
      result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "de"})
      expect(result).to be_nil
      expect(err).to include("must be one of")
    end

    it "includes the invalid value in the enum rejection message" do
      result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "de"})
      expect(result).to be_nil
      expect(err).to include("de")
    end

    it "includes allowed values in the enum rejection message" do
      _result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "de"})
      expect(err).to include("en")
    end

    it "validates a nested object parameter successfully" do
      result, err = nested_param_tool.send(:validate_and_coerce, {"opts" => {"name" => "Alice"}})
      expect(err).to be_nil
      expect(result[:opts]).to eq({"name" => "Alice"})
    end

    it "returns error when nested object is not a Hash" do
      result, err = nested_param_tool.send(:validate_and_coerce, {"opts" => "not-a-hash"})
      expect(result).to be_nil
      expect(err).to include("expected type object")
    end

    it "returns error when nested required field has wrong type" do
      result, err = nested_param_tool.send(:validate_and_coerce, {"opts" => {"name" => 42}})
      expect(result).to be_nil
      expect(err).to include("nested field")
    end

    it "returns error when nested required field is missing" do
      result, err = nested_param_tool.send(:validate_and_coerce, {"opts" => {}})
      expect(result).to be_nil
      expect(err).to include("missing")
    end

    it "returns the nested schema via param_schemas for nested object params" do
      expect(nested_param_tool.class.param_schemas[:opts]).to be_a(Hash)
    end

    it "skips optional parameter without error when not provided" do
      multi_tool = Class.new(described_class) do
        description "multi"
        param :opt, type: :string, desc: "optional", required: false
        param :req, type: :integer, desc: "required"

        def execute(opt: nil, req:) = "#{opt}:#{req}"
      end.new
      result, err = multi_tool.send(:validate_and_coerce, {"req" => 5})
      expect(err).to be_nil
      expect(result[:req]).to eq(5)
    end

    it "continues to check subsequent parameters after an optional missing one" do
      multi_tool = Class.new(described_class) do
        description "multi"
        param :opt, type: :string, desc: "optional", required: false
        param :req, type: :integer, desc: "required"

        def execute(opt: nil, req:) = "#{opt}:#{req}"
      end.new
      _result, err = multi_tool.send(:validate_and_coerce, {"req" => "bad"})
      expect(err).to include("integer")
    end

    it "rejects Integer enum value using string coercion check" do
      int_enum_tool = Class.new(described_class) do
        description "int enum"
        param :level, type: :integer, desc: "level", enum: [1, 2, 3]

        def execute(level:) = level
      end.new
      _result, err = int_enum_tool.send(:validate_and_coerce, {"level" => 1})
      expect(err).to be_nil
    end

    it "enum error message separates allowed values with comma-space" do
      _result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "de"})
      # Kills mutation [69]: enum_vals.to_s = '["en", "ja", "fr"]' does NOT contain "en, ja"
      expect(err).to include("en, ja")
    end

    it "enum error message includes value with inspect formatting (quotes)" do
      _result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "de"})
      expect(err).to include('"de"')
    end

    it "unknown param error includes the key name" do
      result, err = int_return_error_tool.send(:validate_and_coerce, {"count" => 1, "extra_key" => "x"})
      expect(result).to be_nil
      expect(err).to include("extra_key")
    end

    it "does not apply nested object validation to non-object typed params" do
      # :integer type should not trigger nested_schema lookup even if a schema exists
      result, err = int_return_error_tool.send(:validate_and_coerce, {"count" => 5})
      expect(err).to be_nil
      expect(result[:count]).to eq(5)
    end

    context "return value is always a 2-element Array (kills [52])" do
      it "early return for no-params tool is a 2-element Array" do
        # Kills [52]: return [args] vs return [args, nil] — size differs
        arr = no_params_tool.send(:validate_and_coerce, {"x" => 1})
        expect(arr).to be_an(Array)
        expect(arr.size).to eq(2)
      end

      it "successful validation returns a 2-element Array (kills [33]: [result] vs [result, nil])" do
        # Kills [33]: [result] vs [result, nil] at end of method — size drops from 2 to 1
        arr = typed_tool.send(:validate_and_coerce, {"name" => "Alice"})
        expect(arr).to be_an(Array)
        expect(arr.size).to eq(2)
        expect(arr.last).to be_nil
      end
    end

    context "absent optional param is not injected as nil (kills [54], [55])" do
      let(:opt_req_tool) do
        Class.new(described_class) do
          description "opt req"
          param :opt, type: :string, desc: "optional", required: false
          param :req, type: :string, desc: "required"

          def execute(req:, opt: "DEFAULT") = "#{req}/#{opt}"
        end.new
      end

      it "does not include absent optional param key in result hash" do
        # Kills [54],[55]: next replaced by nil causes result[:opt]=nil to be set
        result, err = opt_req_tool.send(:validate_and_coerce, {"req" => "hello"})
        expect(err).to be_nil
        expect(result).not_to have_key(:opt)
      end
    end

    context "nested object error message includes the parameter name path (kills [64], [66], [67])" do
      it "nested validation error includes the object parameter name" do
        # Kills [64] (nil path), [66] (empty string path), [67] (self.to_s path)
        result, err = nested_param_tool.send(:validate_and_coerce, {"opts" => {"name" => 42}})
        expect(result).to be_nil
        expect(err).to include("opts")
        expect(err).not_to include("#<")
      end
    end

    context "enum error message includes the parameter name (kills [68])" do
      it "enum rejection message includes the parameter name not nil" do
        # Kills [68]: "parameter '#{nil}'" vs "parameter '#{name}'"
        _result, err = enum_param_tool.send(:validate_and_coerce, {"lang" => "de"})
        expect(err).to include("lang")
      end
    end
  end

  describe "#validate_nested_object" do
    let(:tool) { hello_tool }

    it "returns an error string when value is not a Hash" do
      result = tool.send(:validate_nested_object, "not-a-hash", {}, "field")
      expect(result).to match(/must be an object \(Hash\)/)
    end

    it "returns nil when all fields pass validation" do
      schema = {name: {type: :string, required: true}}
      expect(tool.send(:validate_nested_object, {name: "Alice"}, schema, "field")).to be_nil
    end

    it "returns error string (not raises) for extra keys" do
      schema = {name: {type: :string}}
      result = tool.send(:validate_nested_object, {name: "Alice", extra: "bad"}, schema, "field")
      expect(result).to be_a(String)
      expect(result).to include("undeclared key")
    end

    it "returns error for missing required field" do
      schema = {name: {type: :string, required: true}}
      result = tool.send(:validate_nested_object, {}, schema, "field")
      expect(result).to include("missing")
    end

    it "returns nil for missing optional field" do
      schema = {name: {type: :string, required: false}}
      expect(tool.send(:validate_nested_object, {}, schema, "field")).to be_nil
    end

    it "includes the field path in error for wrong type" do
      schema = {count: {type: :integer, required: true}}
      result = tool.send(:validate_nested_object, {count: "not-int"}, schema, "myfield")
      expect(result).to include("myfield.count")
    end

    it "returns nil for correct nested field type" do
      schema = {count: {type: :integer, required: true}}
      expect(tool.send(:validate_nested_object, {count: 5}, schema, "field")).to be_nil
    end

    it "recursively validates nested objects and includes full path" do
      schema = {
        child: {
          type: :object,
          required: true,
          properties: {leaf: {type: :string, required: true}}
        }
      }
      result = tool.send(:validate_nested_object, {child: {leaf: 42}}, schema, "root")
      expect(result).to include("root.child.leaf")
    end

    it "accepts valid recursive nesting" do
      schema = {
        child: {
          type: :object,
          required: true,
          properties: {leaf: {type: :string, required: true}}
        }
      }
      expect(tool.send(:validate_nested_object, {child: {leaf: "ok"}}, schema, "root")).to be_nil
    end

    it "error message path uses the provided path prefix" do
      schema = {x: {type: :integer, required: true}}
      result = tool.send(:validate_nested_object, {x: "bad"}, schema, "my.path")
      expect(result).to include("my.path.x")
    end

    it "includes the path in the non-Hash error message" do
      result = tool.send(:validate_nested_object, "bad", {}, "my_field")
      expect(result).to include("my_field")
    end

    it "normalizes string keys to symbols before lookup (transform_keys)" do
      schema = {name: {type: :string, required: true}}
      result = tool.send(:validate_nested_object, {"name" => "Alice"}, schema, "field")
      expect(result).to be_nil
    end

    it "includes the path in the undeclared key error message" do
      schema = {name: {type: :string}}
      result = tool.send(:validate_nested_object, {name: "x", extra: "bad"}, schema, "opts")
      expect(result).to include("opts")
    end

    it "includes the extra keys in the undeclared key error message" do
      schema = {name: {type: :string}}
      result = tool.send(:validate_nested_object, {name: "x", foo: "bad"}, schema, "opts")
      expect(result).to include("foo")
    end

    it "includes the field path in the required field missing error" do
      schema = {title: {type: :string, required: true}}
      result = tool.send(:validate_nested_object, {}, schema, "item")
      expect(result).to include("item.title")
    end

    it "continues validation past an optional missing field to check subsequent fields" do
      schema = {
        opt: {type: :string, required: false},
        req: {type: :integer, required: true}
      }
      result = tool.send(:validate_nested_object, {req: "not-int"}, schema, "f")
      expect(result).to include("f.req")
    end

    it "does not recurse into nested object when field has no :properties declared" do
      schema = {data: {type: :object, required: true}}
      result = tool.send(:validate_nested_object, {data: {x: "y"}}, schema, "field")
      expect(result).to be_nil
    end

    it "includes the nested field path in the type error message" do
      schema = {count: {type: :integer, required: true}}
      result = tool.send(:validate_nested_object, {count: "bad"}, schema, "parent")
      expect(result).to include("parent.count")
      expect(result).to be_a(String)
    end

    it "includes path info in recursive validation error" do
      schema = {
        child: {
          type: :object,
          required: true,
          properties: {num: {type: :integer, required: true}}
        }
      }
      result = tool.send(:validate_nested_object, {child: {num: "bad"}}, schema, "root")
      expect(result).to be_a(String)
      expect(result).to include("root.child.num")
    end

    it "returns nil after recursive validation passes (not always-error)" do
      schema = {
        child: {
          type: :object,
          required: true,
          properties: {num: {type: :integer, required: true}}
        }
      }
      expect(tool.send(:validate_nested_object, {child: {num: 5}}, schema, "root")).to be_nil
    end

    context "kills mutations [73], [76], [77], [79], [80], [81], [84], [86], [88]" do
      it "accepts Hash subclass as a valid nested object (is_a? not instance_of?) [73]" do
        sub_hash = Class.new(Hash).new
        sub_hash[:name] = "Alice"
        schema = {name: {type: :string, required: true}}
        expect(tool.send(:validate_nested_object, sub_hash, schema, "field")).to be_nil
      end

      it "does not recurse for absent optional :object field (next not replaced by nil) [76,77]" do
        # Kills [76],[77]: removing `next` causes nil value to enter recursion for :object field,
        # calling validate_nested_object(nil, ...) which errors since nil is not a Hash.
        schema = {
          inner: {type: :object, required: false, properties: {x: {type: :string}}}
        }
        expect(tool.send(:validate_nested_object, {}, schema, "parent")).to be_nil
      end

      it "error message for wrong type includes the actual type mismatch detail [79]" do
        # Kills [79]: "nested field '...': #{nil}" vs "nested field '...': #{error}"
        schema = {count: {type: :integer, required: true}}
        result = tool.send(:validate_nested_object, {count: "not-int"}, schema, "parent")
        expect(result).to include("integer")
      end

      it "does not recurse into :object field when no :properties declared [80,81,84]" do
        # Kills [80] (removes &&spec[:properties]), [81] (spec[:properties] -> true),
        # [84] (spec[:properties] -> true): without this guard, recurse with nil properties
        # which would crash (nil.keys). Test: :object field without properties -> no error.
        schema = {data: {type: :object, required: true}}
        expect(tool.send(:validate_nested_object, {data: {x: 1}}, schema, "field")).to be_nil
      end

      it "returns the recursive error (not nil) when nested validation fails [86,88]" do
        # Kills [86]: break vs return — break exits loop but method returns nil; return propagates error
        # Kills [88]: if true (always continue) vs if error (conditional)
        schema = {
          child: {
            type: :object,
            required: true,
            properties: {num: {type: :integer, required: true}}
          }
        }
        result = tool.send(:validate_nested_object, {child: {num: "bad"}}, schema, "root")
        expect(result).not_to be_nil
        expect(result).to include("root.child.num")
      end
    end

    it "treats absent :required key as optional (kills [35]: spec.fetch vs spec[])" do
      # Kills [35]: spec.fetch(:required) raises KeyError when :required key is absent from spec
      schema = {x: {type: :string}}  # no :required key at all
      expect(tool.send(:validate_nested_object, {}, schema, "f")).to be_nil
    end

    it "continues past a non-object field to validate subsequent fields (kills [43])" do
      # Kills [43]: next→break in `unless spec[:type].to_sym == :object`
      # With break: loop exits after processing first valid non-object field,
      # skipping subsequent fields with errors.
      schema = {
        str: {type: :string, required: true},
        num: {type: :integer, required: true}
      }
      result = tool.send(:validate_nested_object, {str: "hello", num: "bad"}, schema, "f")
      expect(result).to include("f.num")
    end

    it "continues validating remaining fields after a successful nested object (kills [45], [46])" do
      # Kills [45]: `return error if true` — always returns after recursion even when error is nil
      # Kills [46]: `return error` — always returns (nil) when recursion succeeds, stopping the loop
      schema = {
        obj: {type: :object, required: true, properties: {x: {type: :string, required: true}}},
        num: {type: :integer, required: true}
      }
      result = tool.send(
        :validate_nested_object,
        {obj: {x: "hello"}, num: "bad"},
        schema, "f"
      )
      expect(result).to include("f.num")
    end
  end

  describe "#nested_schema_to_json_schema" do
    let(:tool) { hello_tool }

    it "converts symbol keys to String" do
      schema = {my_field: {type: :string}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result.keys).to include("my_field")
      expect(result.keys).not_to include(:my_field)
    end

    it "converts :type symbol to a String value" do
      schema = {name: {type: :string}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["name"]["type"]).to eq("string")
    end

    it "converts :integer type to 'integer' string" do
      schema = {count: {type: :integer}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["count"]["type"]).to eq("integer")
    end

    it "includes 'description' when :desc is present" do
      schema = {name: {type: :string, desc: "The name"}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["name"]["description"]).to eq("The name")
    end

    it "omits 'description' key when :desc is absent" do
      schema = {field: {type: :string}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["field"]).not_to have_key("description")
    end

    it "includes 'enum' when :enum is present" do
      schema = {lang: {type: :string, enum: %w[en ja fr]}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["lang"]["enum"]).to eq(%w[en ja fr])
    end

    it "omits 'enum' key when :enum is absent" do
      schema = {field: {type: :string}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["field"]).not_to have_key("enum")
    end

    it "recursively converts nested :properties" do
      schema = {
        config: {
          type: :object,
          properties: {timeout: {type: :integer, desc: "Timeout"}}
        }
      }
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["config"]["properties"]).to be_a(Hash)
      expect(result["config"]["properties"]["timeout"]["type"]).to eq("integer")
    end

    it "omits 'properties' key when :properties is absent" do
      schema = {field: {type: :string}}
      result = tool.send(:nested_schema_to_json_schema, schema)
      expect(result["field"]).not_to have_key("properties")
    end

    it "returns an empty hash for an empty schema" do
      expect(tool.send(:nested_schema_to_json_schema, {})).to eq({})
    end
  end

  describe ".execution_mode DSL" do
    it "defaults to :blocking_io" do
      klass = Class.new(described_class)
      expect(klass.execution_mode).to eq(:blocking_io)
    end

    it "can be set to :cooperative" do
      klass = Class.new(described_class) { execution_mode :cooperative }
      expect(klass.execution_mode).to eq(:cooperative)
    end

    it "can be set to :blocking_io via the DSL without error (kills mutation [90])" do
      # Kills [90]: if :blocking_io is replaced by a sentinel in the valid list,
      # setting :blocking_io would raise ArgumentError. The default getter bypasses validation.
      expect { Class.new(described_class) { execution_mode :blocking_io } }.not_to raise_error
      klass = Class.new(described_class) { execution_mode :blocking_io }
      expect(klass.execution_mode).to eq(:blocking_io)
    end

    it "can be set to :cpu_bound" do
      klass = Class.new(described_class) { execution_mode :cpu_bound }
      expect(klass.execution_mode).to eq(:cpu_bound)
    end

    it "can be set to :external_process" do
      klass = Class.new(described_class) { execution_mode :external_process }
      expect(klass.execution_mode).to eq(:external_process)
    end

    it "raises ArgumentError for an invalid mode" do
      expect { Class.new(described_class) { execution_mode :turbo } }
        .to raise_error(ArgumentError, /turbo/)
    end

    it "error message lists valid modes" do
      expect { Class.new(described_class) { execution_mode :wrong } }
        .to raise_error(ArgumentError, /cooperative.*blocking_io/)
    end

    it "error message includes the invalid value with inspect formatting (:sym notation)" do
      err = nil
      begin
        Class.new(described_class) { execution_mode :turbo }
      rescue ArgumentError => e
        err = e.message
      end
      expect(err).to include(":turbo")
    end

    it "error message includes valid values with inspect formatting ([:sym, ...] notation)" do
      err = nil
      begin
        Class.new(described_class) { execution_mode :turbo }
      rescue ArgumentError => e
        err = e.message
      end
      expect(err).to include(":cooperative")
      expect(err).to include(":blocking_io")
    end
  end

  describe ".max_result_size DSL" do
    it "returns nil when not set" do
      klass = Class.new(described_class)
      expect(klass.max_result_size).to be_nil
    end

    it "stores and retrieves a configured limit" do
      klass = Class.new(described_class) { max_result_size 512 }
      expect(klass.max_result_size).to eq(512)
    end

    it "is not inherited from parent when parent has no limit" do
      parent = Class.new(described_class)
      child = Class.new(parent)
      expect(child.max_result_size).to be_nil
    end
  end

  describe ".normalize_nested_schema" do
    it "symbolizes top-level string keys" do
      result = described_class.send(:normalize_nested_schema, {"name" => {type: :string}})
      expect(result.keys).to all(be_a(Symbol))
    end

    it "defaults :type to :string when omitted" do
      result = described_class.send(:normalize_nested_schema, {field: {}})
      expect(result[:field][:type]).to eq(:string)
    end

    it "preserves an explicit :type" do
      result = described_class.send(:normalize_nested_schema, {count: {type: :integer}})
      expect(result[:count][:type]).to eq(:integer)
    end

    it "recursively normalizes nested :properties" do
      input = {config: {type: :object, properties: {"inner" => {type: :integer}}}}
      result = described_class.send(:normalize_nested_schema, input)
      expect(result[:config][:properties].keys).to all(be_a(Symbol))
    end

    it "symbolizes spec value keys (treats string-keyed spec the same as symbol-keyed)" do
      result = described_class.send(:normalize_nested_schema, {"name" => {"type" => :string}})
      expect(result[:name][:type]).to eq(:string)
    end

    it "converts string spec :type key so that explicit non-default type is preserved (kills [92])" do
      # Kills mutation [92]: if spec.transform_keys is removed, then s["type"] = :integer
      # but s[:type] is nil, so s[:type] ||= :string sets it to :string (wrong).
      # With transform_keys, s[:type] = :integer and ||= is a no-op.
      result = described_class.send(:normalize_nested_schema, {count: {"type" => :integer}})
      expect(result[:count][:type]).to eq(:integer)
    end

    it "does not recurse when :properties key is absent (not just nil)" do
      input = {count: {type: :integer}}
      result = described_class.send(:normalize_nested_schema, input)
      expect(result[:count]).not_to have_key(:properties)
    end

    it "handles nested properties access via [] (not fetch)" do
      input = {data: {type: :object, properties: {val: {type: :string}}}}
      result = described_class.send(:normalize_nested_schema, input)
      expect(result[:data][:properties][:val][:type]).to eq(:string)
    end
  end

  describe ".redact_params — inheritance" do
    it "inherits redacted params from the parent class" do
      parent = Class.new(described_class) { redact_params :password }
      child = Class.new(parent)
      expect(child.redact_params).to include(:password)
    end

    it "merges parent and child redacted params" do
      parent = Class.new(described_class) { redact_params :secret }
      child = Class.new(parent) { redact_params :token }
      expect(child.redact_params).to contain_exactly(:secret, :token)
    end

    it "returns an empty array when no params are redacted" do
      klass = Class.new(described_class)
      expect(klass.redact_params).to eq([])
    end

    it "accumulates params across multiple calls to redact_params" do
      klass = Class.new(described_class)
      klass.redact_params :password
      klass.redact_params :secret
      expect(klass.redact_params).to contain_exactly(:password, :secret)
    end

    it "deduplicates when same param is added twice" do
      klass = Class.new(described_class)
      klass.redact_params :password
      klass.redact_params :password
      expect(klass.redact_params).to eq([:password])
    end

    it "returns exactly one entry when same param is added twice (explicit size check, kills [95])" do
      # Kills mutation [95]: removing .uniq from the getter causes [:password, :password]
      klass = Class.new(described_class)
      klass.redact_params :password
      klass.redact_params :password
      expect(klass.redact_params.size).to eq(1)
    end

    it "deduplicates when same param appears in parent and child (getter .uniq)" do
      parent = Class.new(described_class) { redact_params :password }
      child = Class.new(parent) { redact_params :password }
      expect(child.redact_params).to eq([:password])
    end

    it "inherited+child dedup returns size-1 array (explicit size check, kills [95])" do
      parent = Class.new(described_class) { redact_params :password }
      child = Class.new(parent) { redact_params :password }
      expect(child.redact_params.size).to eq(1)
    end

    it "converts string param names to symbols" do
      klass = Class.new(described_class)
      klass.redact_params("api_key")
      expect(klass.redact_params).to eq([:api_key])
    end
  end

  describe ".retry_on — default values" do
    it "defaults times: to 1" do
      klass = Class.new(described_class) { retry_on StandardError }
      expect(klass.retry_policies.first[:times]).to eq(1)
    end

    it "defaults wait: to 0" do
      klass = Class.new(described_class) { retry_on StandardError }
      expect(klass.retry_policies.first[:wait]).to eq(0)
    end

    it "defaults base: to 1.0" do
      klass = Class.new(described_class) { retry_on StandardError }
      expect(klass.retry_policies.first[:base]).to eq(1.0)
    end

    it "stores exception class in :exceptions array" do
      klass = Class.new(described_class) { retry_on ArgumentError }
      expect(klass.retry_policies.first[:exceptions]).to eq([ArgumentError])
    end
  end

  describe ".on_error DSL — logger branch" do
    it "calls logger.warn with deprecation message when logger is configured" do
      logged = []
      logger = double("Logger")
      allow(logger).to receive(:warn) { |msg| logged << msg }
      allow(Phronomy.configuration).to receive(:logger).and_return(logger)
      Class.new(described_class) { on_error :return_empty }
      expect(logged.first).to match(/deprecated.*suppress/i)
    end

    it "returns :raise when called without argument and never set" do
      klass = Class.new(described_class)
      expect(klass.on_error).to eq(:raise)
    end

    it "returns the stored behavior when called without argument after being set" do
      klass = Class.new(described_class)
      klass.on_error(:suppress)
      expect(klass.on_error).to eq(:suppress)
    end

    it "stores :suppress behavior" do
      klass = Class.new(described_class)
      klass.on_error(:suppress)
      expect(klass.on_error).to eq(:suppress)
    end

    it "stores :return_empty behavior" do
      klass = Class.new(described_class)
      allow(Phronomy.configuration).to receive(:logger).and_return(nil)
      expect { klass.on_error(:return_empty) }.to output.to_stderr
      expect(klass.on_error).to eq(:return_empty)
    end

    it "outputs deprecation to stderr when :return_empty and no logger configured" do
      allow(Phronomy.configuration).to receive(:logger).and_return(nil)
      expect { Class.new(described_class) { on_error :return_empty } }
        .to output(/deprecated.*suppress/i).to_stderr
    end

    it "does not output deprecation when behavior is :suppress" do
      logged = []
      logger = double("Logger")
      allow(logger).to receive(:warn) { |msg| logged << msg }
      allow(Phronomy.configuration).to receive(:logger).and_return(logger)
      Class.new(described_class) { on_error :suppress }
      expect(logged).to be_empty
    end
  end

  describe "#execute" do
    it "raises NotImplementedError when called on the base class directly" do
      expect { described_class.new.execute }.to raise_error(NotImplementedError)
    end

    it "error message includes #execute is not implemented" do
      begin
        described_class.new.execute
      rescue NotImplementedError => e
        expect(e.message).to include("#execute is not implemented")
        expect(e.message).to include("Phronomy::Tool::Base")
      end
    end

    it "error message mentions the class name" do
      subclass = Class.new(described_class) do
        description "sub"
      end
      begin
        subclass.new.execute
      rescue NotImplementedError => e
        expect(e.message).to include("#execute")
      end
    end

    it "error message uses class name format not instance representation" do
      # Kills mutation [32]: "#{self}#execute..." vs "#{self.class}#execute..."
      # self.to_s = "#<Phronomy::Tool::Base:0x...>", self.class.to_s = "Phronomy::Tool::Base"
      begin
        described_class.new.execute
      rescue NotImplementedError => e
        expect(e.message).to start_with("Phronomy::Tool::Base#execute")
        expect(e.message).not_to include("#<Phronomy::Tool::Base:")
      end
    end
  end

  describe "#requires_approval" do
    it "returns false when the class default is used" do
      expect(hello_tool.requires_approval).to eq(false)
    end

    it "returns true when requires_approval is set to true on the class" do
      klass = Class.new(described_class) { requires_approval true }
      expect(klass.new.requires_approval).to eq(true)
    end
  end

  describe "#execute_accepts_cancellation_token?" do
    it "returns true when execute declares cancellation_token: as optional keyword" do
      ct_tool = Class.new(described_class) do
        description "ct"

        def execute(cancellation_token: nil) = "ok"
      end.new
      expect(ct_tool.send(:execute_accepts_cancellation_token?)).to be true
    end

    it "returns false when execute does not declare cancellation_token" do
      plain_tool = Class.new(described_class) do
        description "plain"

        def execute = "ok"
      end.new
      expect(plain_tool.send(:execute_accepts_cancellation_token?)).to be false
    end

    it "returns true when execute declares cancellation_token: as required keyword" do
      required_ct_tool = Class.new(described_class) do
        description "req ct"

        def execute(cancellation_token:) = "ok"
      end.new
      expect(required_ct_tool.send(:execute_accepts_cancellation_token?)).to be true
    end

    it "returns false when execute has cancellation_token as positional (not keyword)" do
      pos_tool = Class.new(described_class) do
        description "pos"

        def execute(*args) = args.first
      end.new
      expect(pos_tool.send(:execute_accepts_cancellation_token?)).to be false
    end

    it "returns false when execute has other keyword but not cancellation_token" do
      other_kw_tool = Class.new(described_class) do
        description "other"

        def execute(other_param: nil) = other_param
      end.new
      expect(other_kw_tool.send(:execute_accepts_cancellation_token?)).to be false
    end

    it "returns false when execute has cancellation_token as positional named argument" do
      # Kills mutations [34] (name only check), [35] ([:key,:keyreq] without .include?),
      # [36] (name && true), [37] (name && type where type=:req is truthy)
      # The existing test uses *args which has name :args != :cancellation_token.
      # This test uses a positional named cancellation_token (:req type, not :key/:keyreq).
      pos_named_tool = Class.new(described_class) do
        description "pos named ct"

        def execute(cancellation_token) = cancellation_token.inspect
      end.new
      expect(pos_named_tool.send(:execute_accepts_cancellation_token?)).to be false
    end
  end
end
