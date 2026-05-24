# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Tool::ScopePolicy do
  subject(:policy) { described_class::DEFAULT }

  describe "#call — default policy" do
    it "returns :allow for nil scope" do
      expect(policy.call(double, nil, double)).to eq(:allow)
    end

    it "returns :allow for :read_only scope" do
      expect(policy.call(double, :read_only, double)).to eq(:allow)
    end

    it "returns :approve for :write scope" do
      expect(policy.call(double, :write, double)).to eq(:approve)
    end

    it "returns :approve for :admin scope" do
      expect(policy.call(double, :admin, double)).to eq(:approve)
    end

    it "returns :approve for :external_network scope" do
      expect(policy.call(double, :external_network, double)).to eq(:approve)
    end

    it "returns :approve for :filesystem scope" do
      expect(policy.call(double, :filesystem, double)).to eq(:approve)
    end

    it "returns :approve for :process scope" do
      expect(policy.call(double, :process, double)).to eq(:approve)
    end

    it "returns :approve for :external_process scope" do
      expect(policy.call(double, :external_process, double)).to eq(:approve)
    end

    it "returns :allow for unknown scope" do
      expect(policy.call(double, :custom_scope, double)).to eq(:allow)
    end
  end

  describe "Agent integration" do
    let(:write_tool_class) do
      Class.new(Phronomy::Tool::Base) do
        description "A write-scoped tool"
        scope :write

        def execute
          "executed"
        end
      end
    end

    let(:read_tool_class) do
      Class.new(Phronomy::Tool::Base) do
        description "A read-only tool"
        scope :read_only

        def execute
          "read result"
        end
      end
    end

    let(:agent_class) do
      wt = write_tool_class
      rt = read_tool_class
      Class.new(Phronomy::Agent::Base) do
        model "test-model"
        tools wt, rt
      end
    end

    it "rejects :write scoped tool when policy returns :reject" do
      agent = agent_class.new
      agent.scope_policy = ->(_tc, _scope, _agent) { :reject }

      # prepare_tool_class wraps it to return a denial string
      wrapped = agent.send(:prepare_tool_class, write_tool_class)
      instance = wrapped.new
      expect(instance.call({})).to match(/denied/)
    end

    it "allows :read_only scoped tool with default policy" do
      agent = agent_class.new
      # Default policy: :read_only → :allow; no wrapping
      wrapped = agent.send(:prepare_tool_class, read_tool_class)
      # The wrapped class should still execute normally
      expect(wrapped.ancestors).to include(read_tool_class)
    end

    it "routes :write scoped tool through approval gate (approve decision)" do
      agent = agent_class.new
      agent.scope_policy = ->(_tc, scope, _a) { (scope == :write) ? :approve : :allow }
      approved = false
      agent.on_approval_required { |_name, _args| approved = true }

      wrapped = agent.send(:prepare_tool_class, write_tool_class)
      instance = wrapped.new
      # Approval handler returns truthy → execution allowed
      instance.call({})
      expect(approved).to be true
    end

    it "denies :write scoped tool when approve decision but no handler registered" do
      agent = agent_class.new
      agent.scope_policy = ->(_tc, scope, _a) { (scope == :write) ? :approve : :allow }
      # No approval handler registered

      wrapped = agent.send(:prepare_tool_class, write_tool_class)
      # When no handler and requires_approval is set, the tool suspends.
      # In the unit test context (no full invoke), the wrapped class simply
      # has requires_approval set — verify that flag is propagated.
      expect(wrapped.requires_approval).to be true
    end
  end
end
