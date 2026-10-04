# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe Phronomy::Tool::Schema do
  let(:schema) do
    {"type" => "object", "properties" => {"n" => {"type" => "integer", "minimum" => 1}},
     "required" => ["n"], "additionalProperties" => false}
  end

  [:param, :hash, :dsl].each do |declaration|
    it "validates #{declaration} declarations before executing and publishes the same constraints" do
      executed = []
      klass = Class.new(Phronomy::Tool::Base) do
        description "Validated integer"
        on_schema_error :raise
        define_method(:execute) { |n:|
          executed << n
          n
        }
      end
      case declaration
      when :param then klass.param(:n, type: :integer)
      when :hash then klass.parameters(schema)
      when :dsl then klass.parameters { integer :n }
      end
      tool = klass.new
      expect(tool.parameters_schema.dig("properties", "n", "type")).to eq("integer")
      expect { tool.call({"n" => "2"}) }.to raise_error(Phronomy::ToolError)
      expect { tool.call({}) }.to raise_error(Phronomy::ToolError)
      expect(executed).to be_empty
      expect(tool.call({"n" => 2})).to eq(2)
      expect(executed).to eq([2])
    end
  end

  it "advertises legacy optional nil and coerces a non-null optional value" do
    tool = Class.new(Phronomy::Tool::Base) do
      param :n, type: :integer, required: false, enum: [1, 2]
      on_schema_error :coerce
      def execute(n: 1) = n
    end.new
    expect(tool.parameters_schema.dig("properties", "n", "type")).to eq(["integer", "null"])
    expect(tool.call({n: nil})).to eq(1)
    expect(tool.call({n: "2"})).to eq(2)
    expect(tool.call({})).to eq(1)
    expect(tool.validate_arguments({n: 3}).last).to include("one of")
  end

  it "validates nested required fields, enums, array items and additional properties" do
    definition = Phronomy::Tool::Schema.new({"type" => "object", "properties" => {
      "items" => {"type" => "array", "minItems" => 1, "items" => {
        "type" => "object", "properties" => {"kind" => {"enum" => ["a", "b"]}},
        "required" => ["kind"], "additionalProperties" => false
      }}
    }, "required" => ["items"], "additionalProperties" => false})
    [{}, {items: []}, {items: [{}]}, {items: [{kind: "c"}]}, {items: [{kind: "a", extra: 1}]}].each do |invalid|
      expect(definition.validate(invalid).last).to be_a(String)
    end
    expect(definition.validate({items: [{kind: "b"}]})).to eq([{items: [{kind: "b"}]}, nil])
  end

  it "coerces explicit types without mutating inputs or truncating fractions" do
    definition = Phronomy::Tool::Schema.new(schema)
    input = {"n" => "2"}.freeze
    expect(definition.validate(input, coerce: true)).to eq([{n: 2}, nil])
    expect(input).to eq("n" => "2")
    expect(definition.validate({n: 2.5}, coerce: true).last).to include("fractional")
    expect(definition.validate({n: "bad"}, coerce: true).last).to include("cannot be coerced")
  end

  it "rejects non-finite numbers produced by coercion" do
    definition = Phronomy::Tool::Schema.new({"type" => "object", "properties" => {"n" => {"type" => "number"}}})
    expect(definition.validate({n: "1e9999"}, coerce: true).last).to include("finite")
  end

  it "resolves local references and never guesses a coercion through a reference" do
    definition = Phronomy::Tool::Schema.new({"type" => "object", "$defs" => {"positive" => {"type" => "integer", "minimum" => 1}},
      "properties" => {"n" => {"$ref" => "#/$defs/positive"}}, "required" => ["n"]})
    expect(definition.validate({n: 2}).last).to be_nil
    expect(definition.validate({n: 0}).last).to be_a(String)
    expect(definition.validate({n: "2"}, coerce: true).last).to be_a(String)
  end

  [{"bogus" => true}, {"properties" => []}, {"oneOf" => {}}, {"$ref" => "https://invalid.example/schema"},
    {"$ref" => "#/$defs/missing"}, {"$schema" => "https://invalid.example/meta"},
    {"properties" => {"n" => {"format" => "unknown-format"}}}].each do |invalid|
    it "rejects unsupported or malformed definitions #{invalid.inspect} at construction" do
      expect { Phronomy::Tool::Schema.new({"type" => "object"}.merge(invalid)) }.to raise_error(ArgumentError)
    end
  end

  it "rejects duplicate normalized keys, objects and non-finite values" do
    definition = Phronomy::Tool::Schema.new({"type" => "object"})
    [{:n => 1, "n" => 2}, {n: Object.new}, {n: Float::INFINITY}].each do |input|
      expect(definition.validate(input).last).to be_a(String)
    end
  end

  it "loads and operates Tool and LLM contracts without loading SDK, Agent or Engine" do
    source = <<~SOURCE
      require "phronomy/tool/base"
      require "phronomy/llm_adapter/base"
      Phronomy::RuntimeSettings.install_provider { Phronomy::RuntimeSettings.new(tracer: nil) }
      tool = Class.new(Phronomy::Tool::Base) do
        param :n, type: :integer
        def execute(n:) = n + 1
      end.new
      abort "Tool failed" unless tool.call({n: 2}) == 3
      backend = Class.new(Phronomy::LLMAdapter::Base) do
        protected
        def perform_complete(request, cancellation_token:)
          Phronomy::LLMAdapter::Response.new(content: request.message)
        end
      end.new
      abort "LLM failed" unless backend.complete(Phronomy::LLMAdapter::Request.new(message: "ok")).content == "ok"
      abort "SDK loaded" if defined?(RubyLLM)
      abort "Agent loaded" if Phronomy.const_defined?(:Agent, false)
      abort "Engine loaded" if Phronomy.const_defined?(:Engine, false) || Phronomy.const_defined?(:Runtime, false)
    SOURCE
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", source)
    expect(status.success?).to be(true), [out, err].join("\n")
  end
end
