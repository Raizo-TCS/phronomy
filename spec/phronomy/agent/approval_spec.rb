# frozen_string_literal: true

require "spec_helper"

# ---------------------------------------------------------------------------
# Test tools
# ---------------------------------------------------------------------------
class ApprovalTestTool < Phronomy::Agent::Context::Capability::Base
  tool_name "approval_test"
  description "A tool that does not require approval"
  param :value, type: :string, desc: "Input value"

  def execute(value:)
    "executed: #{value}"
  end
end

class ApprovalRequiredTool < Phronomy::Agent::Context::Capability::Base
  tool_name "approval_required"
  description "A tool that requires approval"
  requires_approval true
  param :value, type: :string, desc: "Input value"

  def execute(value:)
    "executed: #{value}"
  end
end

# ---------------------------------------------------------------------------
# Test agents
# ---------------------------------------------------------------------------
class ApprovalBaseAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalTestTool
end

class ApprovalRequiredBaseAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalRequiredTool
end

class ApprovalReactAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalTestTool
end

class ApprovalRequiredReactAgent < Phronomy::Agent::Base
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalRequiredTool
end

# ---------------------------------------------------------------------------
RSpec.describe "Agent approval gate" do
  describe "#on_approval_required" do
    it "returns self for chaining" do
      agent = ApprovalBaseAgent.new
      result = agent.on_approval_required { |_name, _args| true }
      expect(result).to be(agent)
    end

    it "accepts a block and stores it" do
      agent = ApprovalBaseAgent.new
      called = false
      agent.on_approval_required { |_name, _args| called = true }
      # Verify indirectly via prepare_tool_class wrapping
      wrapped = agent.send(:prepare_tool_class, ApprovalRequiredTool)
      wrapped.new.call({"value" => "test"})
      expect(called).to be true
    end
  end

  describe "#prepare_tool_class" do
    context "when tool does NOT require approval" do
      it "returns the tool class unchanged when no handler is set" do
        agent = ApprovalBaseAgent.new
        result = agent.send(:prepare_tool_class, ApprovalTestTool)
        expect(result).to be(ApprovalTestTool)
      end

      it "returns the tool class unchanged even when a handler is registered" do
        agent = ApprovalBaseAgent.new
        handler_called = false
        agent.on_approval_required { |_name, _args| handler_called = true }
        result = agent.send(:prepare_tool_class, ApprovalTestTool)
        expect(result).to be(ApprovalTestTool)
        expect(handler_called).to be false
      end
    end

    context "when tool requires approval and no handler is registered" do
      it "returns the tool class unchanged (backward-compatible)" do
        agent = ApprovalRequiredBaseAgent.new
        result = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        expect(result).to be(ApprovalRequiredTool)
      end

      it "allows the tool to execute without approval" do
        agent = ApprovalRequiredBaseAgent.new
        tool_instance = agent.send(:prepare_tool_class, ApprovalRequiredTool).new
        output = tool_instance.call({"value" => "hello"})
        expect(output).to eq("executed: hello")
      end
    end

    context "when tool requires approval and handler returns truthy" do
      it "executes the tool and returns its result" do
        agent = ApprovalRequiredBaseAgent.new
        agent.on_approval_required { |_name, _args| true }
        tool_class = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        output = tool_class.new.call({"value" => "approved_value"})
        expect(output).to eq("executed: approved_value")
      end

      it "passes tool name and args to the handler" do
        agent = ApprovalRequiredBaseAgent.new
        received_name = nil
        received_args = nil
        agent.on_approval_required do |name, args|
          received_name = name
          received_args = args
          true
        end
        tool_class = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        tool_class.new.call({"value" => "check_args"})
        expect(received_name).to eq("approval_required")
        expect(received_args).to include("value" => "check_args")
      end
    end

    context "when tool requires approval and handler returns falsy" do
      it "returns a denial message without executing" do
        agent = ApprovalRequiredBaseAgent.new
        agent.on_approval_required { |_name, _args| false }
        tool_class = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        output = tool_class.new.call({"value" => "should_not_run"})
        expect(output).to eq("Tool execution denied.")
      end

      it "does not invoke the tool's execute method" do
        agent = ApprovalRequiredBaseAgent.new
        agent.on_approval_required { |_name, _args| nil }
        tool_class = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        instance = tool_class.new
        expect(instance).not_to receive(:execute)
        instance.call({"value" => "blocked"})
      end
    end

    context "with alias and approval combined" do
      it "applies alias first then wraps with approval gate" do
        aliased_agent_class = Class.new(Phronomy::Agent::Base) do
          model "test-model"
          tools(ApprovalRequiredTool => "aliased_name")
        end
        agent = aliased_agent_class.new
        agent.on_approval_required { |_name, _args| true }
        wrapped = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        # The wrapped class should use the aliased name
        expect(wrapped.new.name).to eq("aliased_name")
        # And it should still execute when approved
        output = wrapped.new.call({"value" => "alias_test"})
        expect(output).to eq("executed: alias_test")
      end
    end

    context "when an instantiated tool object is passed (e.g. Phronomy::Tools::Mcp instance)" do
      it "returns the instance as-is without raising NoMethodError (#383)" do
        # Phronomy::Tools::Mcp.from_server returns an instance, not a class.
        # Simulate with a plain Phronomy::Agent::Context::Capability::Base instance so the test does not require
        # a live MCP server.
        tool_instance = ApprovalTestTool.new
        agent = ApprovalBaseAgent.new
        result = agent.send(:prepare_tool_class, tool_instance)
        expect(result).to equal(tool_instance)
      end

      it "returns the instance unchanged even when an approval handler is registered" do
        tool_instance = ApprovalTestTool.new
        agent = ApprovalBaseAgent.new
        agent.on_approval_required { |_name, _args| true }
        result = agent.send(:prepare_tool_class, tool_instance)
        expect(result).to equal(tool_instance)
      end
    end

    context "with Base subclass" do
      it "wraps requires_approval tool when handler approves" do
        agent = ApprovalRequiredReactAgent.new
        agent.on_approval_required { |_name, _args| true }
        tool_class = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        output = tool_class.new.call({"value" => "react_approved"})
        expect(output).to eq("executed: react_approved")
      end

      it "denies requires_approval tool when handler denies" do
        agent = ApprovalRequiredReactAgent.new
        agent.on_approval_required { |_name, _args| false }
        tool_class = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        output = tool_class.new.call({"value" => "react_denied"})
        expect(output).to eq("Tool execution denied.")
      end
    end
  end
end
