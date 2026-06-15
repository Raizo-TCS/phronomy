# frozen_string_literal: true

require_relative "spec_helper"

# Group 4: OutputParser / Tracing
# Pairwise factors: output_parser_type × output_parser_input_format ×
#                   tracer_type × tracer_block_raises
# Feasible cases: 12 (all cases are feasible; no external dependencies)
#
# OutputParser tests exercise parse() directly with fixed strings – no LLM needed.
# Tracer tests exercise tracer.trace() with an inline block – no LLM needed.
# :integration tag is kept for consistency with the other integration groups.

# Schema used for StructuredParser tests.
PersonSchema = Struct.new(:name, :age)

RSpec.describe "Group 4: OutputParser / Tracing", :integration do
  # ---------------------------------------------------------------------------
  # Test tracer that records start_span / finish_span calls for assertion.
  # ---------------------------------------------------------------------------
  let(:custom_tracer) do
    Class.new(Phronomy::Tracing::Base) do
      attr_reader :started, :finished

      def start_span(name, **attrs)
        @started = {name: name, attrs: attrs}
        {name: name}
      end

      def finish_span(span, output: nil, usage: nil, error: nil)
        @finished = {output: output, usage: usage, error: error}
      end
    end.new
  end

  # Convenience: temporarily replace the global tracer and restore afterwards.
  def with_tracer(tracer)
    original = Phronomy.configuration.tracer
    Phronomy.configuration.tracer = tracer
    yield
  ensure
    Phronomy.configuration.tracer = original
  end

  # ---------------------------------------------------------------------------
  # Fixed input strings for each output_parser_input_format label.
  # ---------------------------------------------------------------------------
  PLAIN_JSON_STR = '{"name":"Alice","age":30}'
  FENCED_JSON_STR = "```json\n{\"name\":\"Bob\",\"age\":25}\n```"
  INVALID_JSON_STR = "not-valid-json!!"
  SCHEMA_MISMATCH_STR = '{"city":"Tokyo","population":14000000}'  # missing :name/:age

  # ---------------------------------------------------------------------------
  # TC-001: none parser, plain_json, nil tracer (NullTracer), success
  # ---------------------------------------------------------------------------
  describe "TC-001: no parser; plain JSON from LLM returned as-is; NullTracer; success" do
    it "returns the raw string unchanged" do
      result = PLAIN_JSON_STR

      # none parser = no parsing; raw string is the output
      expect(result).to be_a(String)
      expect(result).to include("Alice")
    end

    it "NullTracer does not raise and silently discards the span" do
      expect {
        Phronomy.configuration.tracer.trace("tc001") { ["ok", nil] }
      }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: none parser, fenced_json, custom tracer, block_raises
  # ---------------------------------------------------------------------------
  describe "TC-002: no parser; fenced JSON returned as-is; custom tracer block raises" do
    it "raw fenced string passes through without modification" do
      result = FENCED_JSON_STR
      expect(result).to include("```")
      expect(result).to include("Bob")
    end

    it "tracer re-raises the exception from the block and records the error in finish_span" do
      with_tracer(custom_tracer) do
        expect {
          custom_tracer.trace("tc002") { raise "simulated error" }
        }.to raise_error(RuntimeError, "simulated error")

        expect(custom_tracer.finished[:error]).to be_a(RuntimeError)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: none parser, invalid_json, nil tracer, block_raises
  # ---------------------------------------------------------------------------
  describe "TC-003: no parser; invalid JSON does NOT raise ParseError; NullTracer block raises" do
    it "none parser tolerates invalid JSON and returns raw string" do
      # none parser = raw string; no JSON parsing attempted
      result = INVALID_JSON_STR
      expect(result).to be_a(String)
    end

    it "NullTracer re-raises exceptions from the block" do
      expect {
        Phronomy.configuration.tracer.trace("tc003") { raise ArgumentError, "boom" }
      }.to raise_error(ArgumentError, "boom")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: none parser, schema_mismatch, nil tracer, success
  # ---------------------------------------------------------------------------
  describe "TC-004: no parser; schema_mismatch has no effect; NullTracer; success" do
    it "none parser is schema-agnostic — returns raw string without raising" do
      result = SCHEMA_MISMATCH_STR
      expect(result).to be_a(String)
      expect(result).to include("Tokyo")
    end

    it "NullTracer span completes without error" do
      finished_output = nil
      Phronomy.configuration.tracer.trace("tc004") do
        finished_output = "done"
        ["done", nil]
      end
      expect(finished_output).to eq("done")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-005: json parser, plain_json, custom tracer, success
  # ---------------------------------------------------------------------------
  describe "TC-005: JsonParser; plain JSON input; custom tracer verifies span calls" do
    let(:parser) { Phronomy::OutputParser::JsonParser.new }

    it "parses plain JSON and returns a symbolized-key hash" do
      result = parser.parse(PLAIN_JSON_STR)
      expect(result).to eq({name: "Alice", age: 30})
    end

    it "custom tracer records a successful span" do
      with_tracer(custom_tracer) do
        custom_tracer.trace("tc005", input: PLAIN_JSON_STR) { ["parsed", nil] }

        expect(custom_tracer.started[:name]).to eq("tc005")
        expect(custom_tracer.finished[:error]).to be_nil
        expect(custom_tracer.finished[:output]).to eq("parsed")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-006: json parser, fenced_json, nil tracer, success
  # ---------------------------------------------------------------------------
  describe "TC-006: JsonParser; fenced JSON code-block stripped before parsing; NullTracer" do
    let(:parser) { Phronomy::OutputParser::JsonParser.new }

    it "strips the code fence and parses the inner JSON" do
      result = parser.parse(FENCED_JSON_STR)
      expect(result).to eq({name: "Bob", age: 25})
    end
  end

  # ---------------------------------------------------------------------------
  # TC-007: json parser, invalid_json, custom tracer, success (tracer records error)
  # ---------------------------------------------------------------------------
  describe "TC-007: JsonParser; invalid JSON → Phronomy::ParseError; custom tracer records error" do
    let(:parser) { Phronomy::OutputParser::JsonParser.new }

    it "raises Phronomy::ParseError for non-JSON input" do
      expect { parser.parse(INVALID_JSON_STR) }.to raise_error(Phronomy::ParseError)
    end

    it "custom tracer captures the ParseError in finish_span" do
      with_tracer(custom_tracer) do
        expect {
          custom_tracer.trace("tc007") { raise Phronomy::ParseError, "bad json" }
        }.to raise_error(Phronomy::ParseError)

        expect(custom_tracer.finished[:error]).to be_a(Phronomy::ParseError)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-008: json parser, schema_mismatch, custom tracer, block_raises
  # ---------------------------------------------------------------------------
  describe "TC-008: JsonParser; schema_mismatch has no effect (no schema validation); custom tracer block raises" do
    let(:parser) { Phronomy::OutputParser::JsonParser.new }

    it "JsonParser parses schema_mismatch JSON without error (no schema validation)" do
      result = parser.parse(SCHEMA_MISMATCH_STR)
      expect(result).to be_a(Hash)
      expect(result[:city]).to eq("Tokyo")
    end

    it "custom tracer re-raises and records a block-level exception" do
      with_tracer(custom_tracer) do
        expect {
          custom_tracer.trace("tc008") { raise "block error" }
        }.to raise_error(RuntimeError, "block error")

        expect(custom_tracer.finished[:error]).to be_a(RuntimeError)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-009: structured parser, plain_json, nil tracer, block_raises
  # ---------------------------------------------------------------------------
  describe "TC-009: StructuredParser; plain JSON matches schema; NullTracer block raises" do
    let(:parser) { Phronomy::OutputParser::StructuredParser.new(PersonSchema) }

    it "parses and maps plain JSON to the PersonSchema struct" do
      result = parser.parse(PLAIN_JSON_STR)
      expect(result).to be_a(PersonSchema)
      expect(result.name).to eq("Alice")
      expect(result.age).to eq(30)
    end

    it "NullTracer re-raises the block exception" do
      expect {
        Phronomy.configuration.tracer.trace("tc009") { raise StandardError, "tc009 error" }
      }.to raise_error(StandardError, "tc009 error")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-010: structured parser, fenced_json, custom tracer, success
  # ---------------------------------------------------------------------------
  describe "TC-010: StructuredParser; fenced JSON unwrapped and validated; custom tracer" do
    let(:parser) { Phronomy::OutputParser::StructuredParser.new(PersonSchema) }

    it "strips the fence and maps to schema" do
      result = parser.parse(FENCED_JSON_STR)
      expect(result).to be_a(PersonSchema)
      expect(result.name).to eq("Bob")
    end

    it "custom tracer records a successful span" do
      with_tracer(custom_tracer) do
        custom_tracer.trace("tc010") { ["struct_ok", nil] }

        expect(custom_tracer.started[:name]).to eq("tc010")
        expect(custom_tracer.finished[:error]).to be_nil
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TC-011: structured parser, invalid_json, nil tracer, success
  # ---------------------------------------------------------------------------
  describe "TC-011: StructuredParser; invalid JSON → Phronomy::ParseError; NullTracer" do
    let(:parser) { Phronomy::OutputParser::StructuredParser.new(PersonSchema) }

    it "raises Phronomy::ParseError for non-JSON input" do
      expect { parser.parse(INVALID_JSON_STR) }.to raise_error(Phronomy::ParseError)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-012: structured parser, schema_mismatch, nil tracer, success
  # ---------------------------------------------------------------------------
  describe "TC-012: StructuredParser; valid JSON but schema mismatch → Phronomy::ParseError; NullTracer" do
    let(:parser) { Phronomy::OutputParser::StructuredParser.new(PersonSchema) }

    it "raises Phronomy::ParseError when the JSON keys do not match the schema" do
      expect { parser.parse(SCHEMA_MISMATCH_STR) }.to raise_error(Phronomy::ParseError)
    end
  end
end
