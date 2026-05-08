# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"

# ---------------------------------------------------------------------------
# Group 18: approval_spec
#
# Pairwise factors:
#   approval_tool_type × approval_handler_type × agent_class
#
# Generated test cases: 6 (all feasible; no infeasible cases)
#
# Infeasible cases: none
#
# LLM required: No
#   All tests exercise the approval gate wrapping mechanism directly via
#   Agent::Base#prepare_tool_class without invoking the LLM. The wrapped tool
#   class is instantiated and its #call method is exercised with a fixed args
#   hash.
# ---------------------------------------------------------------------------

RSpec.describe "Group 18: approval gate", :integration do
  # TC-001: no_approval, none, base
  # Tool without requires_approval; no handler; Base agent.
  # Expected: prepare_tool_class returns the original class unchanged;
  #           tool executes normally.
  describe "TC-001: no_approval tool; no handler; Base agent" do
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

  # TC-002: no_approval, approves, react
  # Tool without requires_approval; approving handler registered; ReactAgent.
  # Expected: prepare_tool_class returns the original class unchanged
  #           (handler is NOT consulted for non-approval tools);
  #           tool executes normally.
  describe "TC-002: no_approval tool; approving handler; ReactAgent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("no_approval") }
    let(:handler) { IntegrationFactors.approval_handler("approves") }
    let(:agent) { IntegrationFactors.approval_agent("react", tool_class: tool_class, handler: handler) }
    let(:handler_calls) { [] }

    before do
      agent.on_approval_required { |name, args|
        handler_calls << [name, args]
        true
      }
    end

    it "prepare_tool_class returns the original tool class (no wrapping)" do
      expect(agent.send(:prepare_tool_class, tool_class)).to be(tool_class)
    end

    it "handler is NOT invoked for non-approval tools" do
      agent.send(:prepare_tool_class, tool_class).new.call({"value" => "test"})
      expect(handler_calls).to be_empty
    end
  end

  # TC-003: no_approval, denies, base
  # Tool without requires_approval; denying handler registered; Base agent.
  # Expected: handler is NOT consulted; tool executes normally despite deny intent.
  describe "TC-003: no_approval tool; denying handler; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("no_approval") }
    let(:handler) { IntegrationFactors.approval_handler("denies") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "tool executes normally even though handler would deny" do
      result = agent.send(:prepare_tool_class, tool_class).new.call({"value" => "bypass_check"})
      expect(result).to eq("executed: bypass_check")
    end
  end

  # TC-004: requires_approval, none, react
  # Tool with requires_approval; NO handler registered; ReactAgent.
  # Expected: backward-compatible path — tool executes without approval check.
  describe "TC-004: requires_approval tool; no handler; ReactAgent (backward compat)" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("requires_approval") }
    let(:handler) { IntegrationFactors.approval_handler("none") }
    let(:agent) { IntegrationFactors.approval_agent("react", tool_class: tool_class, handler: handler) }

    it "prepare_tool_class returns the original class (no handler → no wrapping)" do
      expect(agent.send(:prepare_tool_class, tool_class)).to be(tool_class)
    end

    it "tool executes without approval check (backward compatible)" do
      result = agent.send(:prepare_tool_class, tool_class).new.call({"value" => "no_handler"})
      expect(result).to eq("executed: no_handler")
    end
  end

  # TC-005: requires_approval, approves, base
  # Tool with requires_approval; approving handler; Base agent.
  # Expected: handler is invoked with (tool_name, args); tool executes normally.
  describe "TC-005: requires_approval tool; approving handler; Base agent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("requires_approval") }
    let(:handler) { IntegrationFactors.approval_handler("approves") }
    let(:agent) { IntegrationFactors.approval_agent("base", tool_class: tool_class, handler: handler) }

    it "tool executes and returns execute result" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      result = wrapped.new.call({"value" => "approved"})
      expect(result).to eq("executed: approved")
    end

    it "wrapped tool preserves the tool name" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      expect(wrapped.new.name).to eq("requires_approval_tool")
    end

    it "handler receives the tool name and args" do
      received = []
      agent.on_approval_required { |name, args|
        received << [name, args]
        true
      }
      wrapped = agent.send(:prepare_tool_class, tool_class)
      wrapped.new.call({"value" => "check_args"})
      expect(received.length).to eq(1)
      expect(received.first[0]).to eq("requires_approval_tool")
      expect(received.first[1]).to include("value" => "check_args")
    end
  end

  # TC-006: requires_approval, denies, react
  # Tool with requires_approval; denying handler; ReactAgent.
  # Expected: handler is invoked and returns false → tool returns denial message,
  #           execute is never called.
  describe "TC-006: requires_approval tool; denying handler; ReactAgent" do
    let(:tool_class) { IntegrationFactors.approval_tool_class("requires_approval") }
    let(:handler) { IntegrationFactors.approval_handler("denies") }
    let(:agent) { IntegrationFactors.approval_agent("react", tool_class: tool_class, handler: handler) }

    it "tool returns a denial message" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      result = wrapped.new.call({"value" => "dangerous"})
      expect(result).to eq("Tool execution denied.")
    end

    it "execute is never called on denial" do
      wrapped = agent.send(:prepare_tool_class, tool_class)
      instance = wrapped.new
      expect(instance).not_to receive(:execute)
      instance.call({"value" => "blocked"})
    end
  end
end
