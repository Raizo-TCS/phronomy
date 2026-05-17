# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Test tools
# ---------------------------------------------------------------------------

# Default behavior: on_schema_error not set → :return_error
class SchemaErrorDefaultTool < Phronomy::Tool::Base
  tool_name "schema_default"
  description "Tool with default schema error behavior"
  param :count, type: :integer, desc: "A count"
  param :label, type: :string, desc: "A label"

  def execute(count:, label:)
    "count=#{count} label=#{label}"
  end
end

# on_schema_error :return_error (explicit)
class SchemaErrorReturnTool < Phronomy::Tool::Base
  tool_name "schema_return"
  description "Tool that returns error to LLM on schema violation"
  on_schema_error :return_error
  param :value, type: :integer, desc: "An integer value"

  def execute(value:)
    "value=#{value}"
  end
end

# on_schema_error :raise
class SchemaErrorRaiseTool < Phronomy::Tool::Base
  tool_name "schema_raise"
  description "Tool that raises on schema violation"
  on_schema_error :raise
  param :value, type: :integer, desc: "An integer value"

  def execute(value:)
    "value=#{value}"
  end
end

# on_schema_error :coerce
class SchemaErrorCoerceTool < Phronomy::Tool::Base
  tool_name "schema_coerce"
  description "Tool that coerces arguments"
  on_schema_error :coerce
  param :count, type: :integer, desc: "An integer count"
  param :ratio, type: :number, desc: "A numeric ratio"
  param :active, type: :boolean, desc: "A boolean flag"

  def execute(count:, ratio:, active:)
    "count=#{count} ratio=#{ratio} active=#{active}"
  end
end

# Tool with enum constraint
class SchemaErrorEnumTool < Phronomy::Tool::Base
  tool_name "schema_enum"
  description "Tool with enum constraint"
  param :lang, type: :string, desc: "Language", enum: %w[en ja fr]

  def execute(lang:)
    "lang=#{lang}"
  end
end

# Tool combining :coerce + enum
class SchemaErrorCoerceEnumTool < Phronomy::Tool::Base
  tool_name "schema_coerce_enum"
  description "Tool with coerce and enum"
  on_schema_error :coerce
  param :lang, type: :string, desc: "Language", enum: %w[en ja fr]

  def execute(lang:)
    "lang=#{lang}"
  end
end

# ---------------------------------------------------------------------------

RSpec.describe "Tool::Base on_schema_error" do
  describe ".on_schema_error DSL" do
    it "defaults to :return_error when not set" do
      expect(SchemaErrorDefaultTool.on_schema_error).to eq(:return_error)
    end

    it "can be set to :return_error explicitly" do
      expect(SchemaErrorReturnTool.on_schema_error).to eq(:return_error)
    end

    it "can be set to :raise" do
      expect(SchemaErrorRaiseTool.on_schema_error).to eq(:raise)
    end

    it "can be set to :coerce" do
      expect(SchemaErrorCoerceTool.on_schema_error).to eq(:coerce)
    end
  end

  describe "#call — type validation" do
    context "when args match declared types" do
      it "executes normally (integer param)" do
        result = SchemaErrorDefaultTool.new.call({"count" => 3, "label" => "ok"})
        expect(result).to eq("count=3 label=ok")
      end

      it "rejects numeric strings as integers in :return_error mode" do
        # In strict :return_error mode, "3" (String) does not satisfy :integer.
        # Use :coerce mode if string-to-integer coercion is desired.
        result = SchemaErrorDefaultTool.new.call({"count" => "3", "label" => "ok"})
        expect(result).to be_a(String)
        expect(result).to start_with("Schema validation failed:")
      end
    end

    context "on_schema_error :return_error (default)" do
      it "returns an error string when a non-numeric string is passed for integer param" do
        result = SchemaErrorReturnTool.new.call({"value" => "not_a_number"})
        expect(result).to be_a(String)
        expect(result).to start_with("Schema validation failed:")
      end

      it "returns an error string when wrong type (Array for integer)" do
        result = SchemaErrorDefaultTool.new.call({"count" => [1, 2], "label" => "x"})
        expect(result).to be_a(String)
        expect(result).to start_with("Schema validation failed:")
      end

      it "does NOT raise" do
        expect { SchemaErrorReturnTool.new.call({"value" => "bad"}) }.not_to raise_error
      end
    end

    context "on_schema_error :raise" do
      it "raises Phronomy::ToolError on type violation" do
        expect {
          SchemaErrorRaiseTool.new.call({"value" => "not_an_int"})
        }.to raise_error(Phronomy::ToolError, /schema error/)
      end

      it "does not raise when args are valid" do
        expect {
          SchemaErrorRaiseTool.new.call({"value" => 42})
        }.not_to raise_error
      end
    end

    context "on_schema_error :coerce" do
      it "coerces numeric string to integer" do
        result = SchemaErrorCoerceTool.new.call({"count" => "7", "ratio" => "3.14", "active" => "true"})
        expect(result).to eq("count=7 ratio=3.14 active=true")
      end

      it "coerces string 'true'/'false' to boolean" do
        result = SchemaErrorCoerceTool.new.call({"count" => 1, "ratio" => 1.0, "active" => "false"})
        expect(result).to eq("count=1 ratio=1.0 active=false")
      end

      it "returns error string when coercion is impossible" do
        result = SchemaErrorCoerceTool.new.call({"count" => "not_a_number", "ratio" => 1.0, "active" => true})
        expect(result).to be_a(String)
        expect(result).to start_with("Schema validation failed:")
      end
    end
  end

  describe "#call — enum validation" do
    it "executes normally for a valid enum value" do
      result = SchemaErrorEnumTool.new.call({"lang" => "en"})
      expect(result).to eq("lang=en")
    end

    it "returns error string for an invalid enum value (default :return_error)" do
      result = SchemaErrorEnumTool.new.call({"lang" => "de"})
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
      expect(result).to include("en", "ja", "fr")
    end

    it "also rejects invalid enum after successful coercion" do
      result = SchemaErrorCoerceEnumTool.new.call({"lang" => "de"})
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end

    it "accepts valid enum value in coerce mode" do
      result = SchemaErrorCoerceEnumTool.new.call({"lang" => "ja"})
      expect(result).to eq("lang=ja")
    end
  end

  describe "#call — extra parameters (pass-through)" do
    it "does not reject unknown keys not declared in parameters" do
      # RubyLLM validates required/optional via execute signature, not schema.
      # Extra keys are passed through the validator.
      expect {
        SchemaErrorDefaultTool.new.call({"count" => 1, "label" => "x", "extra" => "ignored"})
      }.not_to raise_error
    end
  end
end
