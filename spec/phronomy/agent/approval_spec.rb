# frozen_string_literal: true

require "spec_helper"

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

class ApprovalBaseAgent < Phronomy::Agent::Base
  agent_definition id: "approval-base-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalTestTool => nil
end

class ApprovalRequiredBaseAgent < Phronomy::Agent::Base
  agent_definition id: "approval-required-base-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalRequiredTool => nil
end

class ApprovalReactAgent < Phronomy::Agent::Base
  agent_definition id: "approval-react-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalTestTool => nil
end

class ApprovalRequiredReactAgent < Phronomy::Agent::Base
  agent_definition id: "approval-required-react-agent", version: 1
  model "test-model"
  instructions "You are a helpful assistant."
  tools ApprovalRequiredTool => nil
end

RSpec.describe "Agent approval gate" do
  describe "#tool_approval_policy" do
    it "returns self for chaining" do
      agent = ApprovalBaseAgent.new
      result = agent.tool_approval_policy { :allow }
      expect(result).to be(agent)
    end

    it "accepts a block" do
      agent = ApprovalBaseAgent.new
      expect { agent.tool_approval_policy { :allow } }.not_to raise_error
    end

    it "raises ArgumentError when called without a block" do
      agent = ApprovalBaseAgent.new
      expect { agent.tool_approval_policy }.to raise_error(ArgumentError, /block/)
    end
  end

  describe "#on_tool_approval_required" do
    it "returns self for chaining" do
      agent = ApprovalBaseAgent.new
      result = agent.on_tool_approval_required { |_req| }
      expect(result).to be(agent)
    end

    it "accepts a block" do
      agent = ApprovalBaseAgent.new
      expect { agent.on_tool_approval_required { |_req| } }.not_to raise_error
    end

    it "raises ArgumentError when called without a block" do
      agent = ApprovalBaseAgent.new
      expect { agent.on_tool_approval_required }.to raise_error(ArgumentError, /block/)
    end
  end

  describe "#prepare_tool_class" do
    context "when tool does NOT require approval" do
      it "returns the tool class unchanged when no policy is set" do
        agent = ApprovalBaseAgent.new
        result = agent.send(:prepare_tool_class, ApprovalTestTool)
        expect(result).to be(ApprovalTestTool)
      end

      it "returns the tool class unchanged even when a policy is registered" do
        agent = ApprovalBaseAgent.new
        agent.tool_approval_policy { :allow }
        result = agent.send(:prepare_tool_class, ApprovalTestTool)
        expect(result).to be(ApprovalTestTool)
      end
    end

    context "when tool requires approval" do
      it "returns the tool class unchanged (authorization is handled by ToolInvocation)" do
        agent = ApprovalRequiredBaseAgent.new
        result = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        expect(result).to be(ApprovalRequiredTool)
      end

      it "allows the tool to execute directly (ToolInvocation is the authorization gate)" do
        agent = ApprovalRequiredBaseAgent.new
        tool_instance = agent.send(:prepare_tool_class, ApprovalRequiredTool).new
        output = tool_instance.call({"value" => "hello"})
        expect(output).to eq("executed: hello")
      end
    end

    context "when an instantiated tool object is passed (e.g. Phronomy::Tools::Mcp instance)" do
      it "returns the instance as-is without raising NoMethodError (#383)" do
        tool_instance = ApprovalTestTool.new
        agent = ApprovalBaseAgent.new
        result = agent.send(:prepare_tool_class, tool_instance)
        expect(result).to equal(tool_instance)
      end

      it "returns the instance unchanged even when a policy is registered" do
        tool_instance = ApprovalTestTool.new
        agent = ApprovalBaseAgent.new
        agent.tool_approval_policy { :allow }
        result = agent.send(:prepare_tool_class, tool_instance)
        expect(result).to equal(tool_instance)
      end
    end

    context "with alias" do
      it "applies alias to tool class" do
        aliased_agent_class = Class.new(Phronomy::Agent::Base) do
          agent_definition id: "test-agent-37", version: 1
          model "test-model"
          tools(ApprovalRequiredTool => "aliased_name")
        end
        agent = aliased_agent_class.new
        wrapped = agent.send(:prepare_tool_class, ApprovalRequiredTool)
        expect(wrapped.new.name).to eq("aliased_name")
      end
    end
  end
end
