# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# Group 18: Tool approval gate
#
# Pairwise factors:
#   approval_tool_type × approval_policy_type × agent_class
#
# NOTE: Updated for 0.15.0 Invocation architecture.
#   - Authorization is handled by ToolInvocation, not by prepare_tool_class wrappers.
#   - tool_approval_policy replaces on_approval_required inline decision.
#   - prepare_tool_class only applies aliases and result filters.

RSpec.describe "Group 18: Tool approval gate", :integration do
  # TC-001: no_approval tool; no policy; Base agent.
  # prepare_tool_class returns the original class unchanged.
  describe "TC-001: no_approval tool; no policy; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("no_approval") }
    let(:handler) { IntegrationFactors.approval_handler("none") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "prepare_tool_class returns the original tool class" do
      expect(agent.send(:prepare_tool_class, tool_class)).to be(tool_class)
    end

    it "tool executes without approval check" do
      result = agent.send(:prepare_tool_class, tool_class).new.call({"value" => "hello"})
      expect(result).to eq("executed: hello")
    end
  end

  # TC-002: no_approval tool; policy :allow; Base agent.
  # prepare_tool_class returns original class; policy is not consulted (no requires_approval).
  describe "TC-002: no_approval tool; policy :allow; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("no_approval") }
    let(:handler) { IntegrationFactors.approval_handler("approves") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "prepare_tool_class returns the original tool class (no wrapping)" do
      expect(agent.send(:prepare_tool_class, tool_class)).to be(tool_class)
    end

    it "tool executes normally" do
      result = agent.send(:prepare_tool_class, tool_class).new.call({"value" => "test"})
      expect(result).to eq("executed: test")
    end
  end

  # TC-003: no_approval tool; policy :reject; Base agent.
  # policy is NOT consulted for non-approval tools; tool executes normally.
  describe "TC-003: no_approval tool; policy :reject; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("no_approval") }
    let(:handler) { IntegrationFactors.approval_handler("denies") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "tool executes normally even with a rejecting policy (no requires_approval)" do
      result = agent.send(:prepare_tool_class, tool_class).new.call({"value" => "bypass_check"})
      expect(result).to eq("executed: bypass_check")
    end
  end

  # TC-004: requires_approval tool; no policy; Base agent.
  # prepare_tool_class returns original class (no inline wrapper in 0.15.0).
  describe "TC-004: requires_approval tool; no policy; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("requires_approval") }
    let(:handler) { IntegrationFactors.approval_handler("none") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "prepare_tool_class returns the original class (no handler -> no inline wrapping)" do
      expect(agent.send(:prepare_tool_class, tool_class)).to be(tool_class)
    end

    it "tool#call executes directly (authorization is ToolInvocation's responsibility)" do
      result = agent.send(:prepare_tool_class, tool_class).new.call({"value" => "no_handler"})
      expect(result).to eq("executed: no_handler")
    end
  end

  # TC-005: requires_approval tool; policy :allow; Base agent.
  # Authorization is handled by ToolInvocation; prepare_tool_class does not wrap.
  describe "TC-005: requires_approval tool; policy :allow; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("requires_approval") }
    let(:handler) { IntegrationFactors.approval_handler("approves") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "prepare_tool_class does not add an approval wrapper" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      # In 0.15.0, prepare_tool_class only handles alias/filter; no inline approval gate.
      result = wrapped.new.call({"value" => "allowed"})
      expect(result).to eq("executed: allowed")
    end

    it "wrapped tool preserves the tool name" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      expect(wrapped.new.name).to eq("requires_approval_tool")
    end
  end

  # TC-006: requires_approval tool; policy :reject; Base agent.
  # Rejection happens at ToolInvocation level, not inside prepare_tool_class.
  describe "TC-006: requires_approval tool; policy :reject; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("requires_approval") }
    let(:handler) { IntegrationFactors.approval_handler("denies") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "prepare_tool_class still allows Tool#call directly (rejection is ToolInvocation's job)" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      # Direct Tool#call bypasses ToolInvocation authorization.
      result = wrapped.new.call({"value" => "direct_call"})
      expect(result).to eq("executed: direct_call")
    end

    it "agent tool_approval_policy returns :reject for this agent" do
      policy = agent.instance_variable_get(:@tool_approval_policy)
      expect(policy).to be_a(Proc)
      expect(policy.call(double("request"))).to eq(:reject)
    end
  end
end
