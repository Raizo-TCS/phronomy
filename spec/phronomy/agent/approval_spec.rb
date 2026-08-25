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
  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe "#tool_approval_policy" do
    it "returns self for chaining" do
      agent = ApprovalBaseAgent.new
      expect(agent.tool_approval_policy { :allow }).to be(agent)
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

  describe "approval notification API" do
    it "does not expose the removed #on_tool_approval_required registration method" do
      expect(ApprovalBaseAgent.new).not_to respond_to(:on_tool_approval_required)
    end

    it "accepts the canonical Agent-incarnation on_event listener" do
      listener = ->(_event) {}
      agent = ApprovalBaseAgent.new(on_event: listener)
      expect(agent).to be_a(ApprovalBaseAgent)
    end

    it "rejects on_event plus a construction block" do
      expect {
        ApprovalBaseAgent.new(on_event: ->(_event) {}) { |_event| }
      }.to raise_error(ArgumentError, /on_event.*block|block.*on_event/i)
    end
  end

  describe "#prepare_tool_class" do
    context "when tool does NOT require approval" do
      it "returns the tool class unchanged when no policy is set" do
        agent = ApprovalBaseAgent.new
        expect(agent.send(:prepare_tool_class, ApprovalTestTool)).to be(ApprovalTestTool)
      end

      it "returns the tool class unchanged even when a policy is registered" do
        agent = ApprovalBaseAgent.new
        agent.tool_approval_policy { :allow }
        expect(agent.send(:prepare_tool_class, ApprovalTestTool)).to be(ApprovalTestTool)
      end
    end

    context "when tool requires approval" do
      it "returns the tool class unchanged because ToolInvocation owns authorization" do
        agent = ApprovalRequiredBaseAgent.new
        expect(agent.send(:prepare_tool_class, ApprovalRequiredTool))
          .to be(ApprovalRequiredTool)
      end

      it "allows direct Tool execution outside the Agent authorization path" do
        agent = ApprovalRequiredBaseAgent.new
        tool_instance = agent.send(:prepare_tool_class, ApprovalRequiredTool).new
        expect(tool_instance.call({"value" => "hello"})).to eq("executed: hello")
      end
    end

    context "when an instantiated tool object is passed" do
      it "returns the instance as-is" do
        tool_instance = ApprovalTestTool.new
        agent = ApprovalBaseAgent.new
        expect(agent.send(:prepare_tool_class, tool_instance)).to equal(tool_instance)
      end

      it "returns the instance unchanged even when a policy is registered" do
        tool_instance = ApprovalTestTool.new
        agent = ApprovalBaseAgent.new
        agent.tool_approval_policy { :allow }
        expect(agent.send(:prepare_tool_class, tool_instance)).to equal(tool_instance)
      end
    end

    context "with alias" do
      it "applies alias to tool class" do
        aliased_agent_class = Class.new(Phronomy::Agent::Base) do
          agent_definition id: "test-agent-37", version: 1
          model "test-model"
          tools(ApprovalRequiredTool => "aliased_name")
        end
        wrapped = aliased_agent_class.new.send(:prepare_tool_class, ApprovalRequiredTool)
        expect(wrapped.new.name).to eq("aliased_name")
      end
    end
  end
end
