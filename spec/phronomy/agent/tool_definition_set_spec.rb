# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolDefinitionSet do
  describe ".normalize" do
    subject(:normalize) { described_class.method(:normalize) }

    it "converts Array elements recursively" do
      result = described_class.normalize([:a, "b", 1])
      expect(result).to eq(["a", "b", 1])
    end

    it "converts Symbol to String" do
      expect(described_class.normalize(:my_key)).to eq("my_key")
    end

    it "passes through String values unchanged" do
      expect(described_class.normalize("hello")).to eq("hello")
    end

    it "passes through Integer values unchanged" do
      expect(described_class.normalize(42)).to eq(42)
    end

    it "passes through nil unchanged" do
      expect(described_class.normalize(nil)).to be_nil
    end
  end
  describe "RubyLLM 2 schema persistence and comparison" do
    let(:tool) do
      Class.new(Phronomy::Tool::Base) do
        tool_name "lookup"
        description "Look up a record"
        param :query, type: :string, required: true, enum: ["1", "2"]
        provider_options strict: true
        def execute(query:) = query
      end
    end
    let(:agent) do
      selected_tool = tool
      Class.new(Phronomy::Agent::Base) do
        tools selected_tool => nil
      end.allocate
    end
    let(:definitions) { described_class.build(agent) }

    it "records the actual arguments and provider options, with an immutable round trip" do
      saved = definitions.definitions
      schema = saved.first.fetch("parameters_schema")
      expect(schema.dig("properties", "query", "type")).to eq("string")
      expect(schema.dig("properties", "query", "enum")).to eq(%w[1 2])
      expect(schema["required"]).to include("query")
      expect(saved.first["provider_options"]).to eq("strict" => true)
      persisted = Phronomy::CanonicalJSON.load(Phronomy::CanonicalJSON.dump(saved))
      expect(described_class.build(agent).select_definitions(persisted).definitions).to eq(saved)
    end

    [:type, :required, :enum, :provider_options].each do |change|
      it "refuses replay after #{change} changes" do
        saved = definitions.definitions
        case change
        when :type then tool.param :query, type: :integer, required: true
        when :required then tool.param :query, type: :string, required: false
        when :enum then tool.param :query, type: :string, enum: ["third"]
        when :provider_options then tool.provider_options strict: false
        end
        expect { described_class.build(agent).select_definitions(saved) }
          .to raise_error(Phronomy::ConfigurationError, /definition changed/)
      end
    end

    it "fails closed for historical empty schemas instead of inferring missing history" do
      saved = definitions.definitions.map { |definition| definition.merge("parameters_schema" => {}, "provider_options" => {}) }
      expect { definitions.select_definitions(saved) }
        .to raise_error(Phronomy::ConfigurationError, /original version before upgrading/)
    end
  end
end
