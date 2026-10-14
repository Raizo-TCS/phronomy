# frozen_string_literal: true

require "spec_helper"
RSpec.describe Phronomy::OutputParser::JsonSchemaParser do
  let(:schema) { {type: "object", properties: {score: {type: "number", minimum: 0, maximum: 1}, note: {type: ["string", "null"]}}, required: %w[score note], additionalProperties: false} }
  subject(:parser) { described_class.new(schema: schema) }
  it "snapshots schema and returns immutable String-key JSON without coercion" do
    parser
    schema[:properties][:score][:minimum] = 9
    result = parser.invoke('{"score":0,"note":null}')
    expect(result).to eq("score" => 0, "note" => nil)
    expect(result).to be_frozen
    expect(parser.json_schema["properties"]["score"]).to be_frozen
  end
  ['```json\n{}\n```', "{} trailing", '{"score":0,"score":1,"note":null}', '{"score":NaN}', '{"score":1e999}', "not JSON"].each do |text|
    it "rejects strict JSON violation #{text.inspect}" do
      expect { parser.parse(text) }.to raise_error(Phronomy::ParseError) { |error|
        expect(error.code).to eq("output_parser.invalid_json")
        expect(error.details.first).to include("pointer", "keyword")
      }
    end
  end
  ["{}", '{"score":"0","note":null}', '{"score":2,"note":null}', '{"score":0,"note":null,"extra":1}'].each do |text|
    it "preserves schema mismatch #{text.inspect} without defaults/clamping" do
      expect { parser.parse(text) }.to raise_error(Phronomy::ParseError) { |error|
        expect(error.code).to eq("output_parser.schema_mismatch")
        expect(error.details).to be_frozen
      }
    end
  end
  [{:type => "object", "$ref" => "#"}, {:type => "object", "$ref" => "https://example.org/schema"},
    {:type => "object", "$ref" => "#/$defs/missing"}, {type: "object", unknown: true},
    {type: "object", properties: {a: {type: "bogus"}}}, {type: "object", properties: {a: {pattern: "["}}},
    {:type => "object", "type" => "object"}].each do |invalid|
    it "rejects invalid schema #{invalid.inspect}" do
      expect { described_class.new(schema: invalid) }.to raise_error(ArgumentError)
    end
  end
  it "supports local references, nested choices, arrays and boolean schemas" do
    parser = described_class.new(schema: {:type => "object", "$defs" => {label: {type: "string"}},
                                          :properties => {labels: {type: "array", items: {"$ref" => "#/$defs/label"}, minItems: 1},
                                                          optional: {anyOf: [{type: "null"}, {type: "number"}]}, anything: true}, :additionalProperties => false})
    expect(parser.parse('{"labels":["x"],"optional":null,"anything":false}')["labels"]).to eq(["x"])
  end
end
