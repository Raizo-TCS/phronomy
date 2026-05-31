# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 19 — on_schema_error policy × schema_violation_kind
#
# These tests call Phronomy::Agent::Context::Capability::Base#call directly (no LLM, no network).
# All 15 pairwise cases are feasible.
#
# Evidence: docs/integration_test_cases_schema_error.yaml

RSpec.describe "on_schema_error integration", :integration do
  let(:valid_args) { {"count" => 3, "mode" => "fast"} }
  let(:wrong_type_args) { {"count" => [1, 2], "mode" => "fast"} }
  let(:bad_enum_args) { {"count" => 1, "mode" => "turbo"} }
  let(:coercible_args) { {"count" => "7", "mode" => "slow"} }
  let(:uncoercible_args) { {"count" => "abc", "mode" => "fast"} }

  # ── policy: return_error ─────────────────────────────────────────────────

  context "TC-001 — return_error × valid" do
    it "executes normally and returns the tool result" do
      tool = IntegrationFactors.schema_error_tool("return_error").new
      expect(tool.call(valid_args)).to eq("ok: count=3 mode=fast")
    end
  end

  context "TC-002 — return_error × wrong_type" do
    it "returns a Schema validation failed string without raising" do
      tool = IntegrationFactors.schema_error_tool("return_error").new
      result = tool.call(wrong_type_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end
  end

  context "TC-003 — return_error × bad_enum" do
    it "returns a Schema validation failed string listing allowed values" do
      tool = IntegrationFactors.schema_error_tool("return_error").new
      result = tool.call(bad_enum_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
      expect(result).to include("fast", "slow")
    end
  end

  context "TC-004 — return_error × coercible" do
    # In strict :return_error mode, a numeric string like "7" does NOT satisfy
    # the :integer type check — only a Ruby Integer passes.  The tool returns
    # a schema error string.
    it "returns a schema error because numeric string is rejected in strict mode" do
      tool = IntegrationFactors.schema_error_tool("return_error").new
      result = tool.call(coercible_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end
  end

  context "TC-005 — return_error × uncoercible" do
    it "returns a Schema validation failed string for uncoercible input" do
      tool = IntegrationFactors.schema_error_tool("return_error").new
      result = tool.call(uncoercible_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end
  end

  # ── policy: raise ────────────────────────────────────────────────────────

  context "TC-006 — raise × valid" do
    it "executes normally and does not raise" do
      tool = IntegrationFactors.schema_error_tool("raise").new
      expect { tool.call(valid_args) }.not_to raise_error
      expect(tool.call(valid_args)).to eq("ok: count=3 mode=fast")
    end
  end

  context "TC-007 — raise × wrong_type" do
    it "raises Phronomy::ToolError containing 'schema error'" do
      tool = IntegrationFactors.schema_error_tool("raise").new
      expect {
        tool.call(wrong_type_args)
      }.to raise_error(Phronomy::ToolError, /schema error/)
    end
  end

  context "TC-008 — raise × bad_enum" do
    it "raises Phronomy::ToolError for bad enum value" do
      tool = IntegrationFactors.schema_error_tool("raise").new
      expect {
        tool.call(bad_enum_args)
      }.to raise_error(Phronomy::ToolError, /schema error/)
    end
  end

  context "TC-009 — raise × coercible" do
    # In strict :raise mode, a numeric string like "7" does NOT satisfy the
    # :integer type check — ToolError is raised.
    it "raises ToolError because numeric string is rejected in strict mode" do
      tool = IntegrationFactors.schema_error_tool("raise").new
      expect { tool.call(coercible_args) }.to raise_error(Phronomy::ToolError, /schema error/)
    end
  end

  context "TC-010 — raise × uncoercible" do
    it "raises ToolError for uncoercible input" do
      tool = IntegrationFactors.schema_error_tool("raise").new
      expect {
        tool.call(uncoercible_args)
      }.to raise_error(Phronomy::ToolError)
    end
  end

  # ── policy: coerce ───────────────────────────────────────────────────────

  context "TC-011 — coerce × valid" do
    it "executes normally when args already match declared types" do
      tool = IntegrationFactors.schema_error_tool("coerce").new
      expect(tool.call(valid_args)).to eq("ok: count=3 mode=fast")
    end
  end

  context "TC-012 — coerce × wrong_type (non-coercible)" do
    it "returns error string when coercion cannot fix the type mismatch" do
      # Array for :integer cannot be coerced to Integer
      tool = IntegrationFactors.schema_error_tool("coerce").new
      result = tool.call(wrong_type_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end
  end

  context "TC-013 — coerce × bad_enum" do
    it "returns error string because enum constraint is enforced even after coercion" do
      tool = IntegrationFactors.schema_error_tool("coerce").new
      result = tool.call(bad_enum_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end
  end

  context "TC-014 — coerce × coercible" do
    it "coerces the numeric string to integer and executes successfully" do
      tool = IntegrationFactors.schema_error_tool("coerce").new
      result = tool.call(coercible_args)
      expect(result).to eq("ok: count=7 mode=slow")
    end
  end

  context "TC-015 — coerce × uncoercible" do
    it "returns error string when coercion also fails" do
      tool = IntegrationFactors.schema_error_tool("coerce").new
      result = tool.call(uncoercible_args)
      expect(result).to be_a(String)
      expect(result).to start_with("Schema validation failed:")
    end
  end
end
