# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Domain settings boundaries" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "domain-settings-agent", version: 1
    end
  end

  it "lets Agent read its domain values without accessing application configuration" do
    settings = Phronomy::Agent::Settings.new(llm_adapter: nil, authorization_timeout: 5, stream_callback_error_policy: :report)
    settings.default_model = "injected-model"
    klass = agent_class
    Phronomy::Agent::Settings.install_provider { settings }
    RSpec::Mocks.with_temporary_scope do
      expect(Phronomy).not_to receive(:configuration)
      expect(klass.model).to eq("injected-model")
      settings.default_model = "next-model"
      expect(klass.model).to eq("next-model")
    end
  ensure
    Phronomy::Agent::Settings.install_provider { Phronomy.configuration.__agent_settings }
  end

  it "retains late model reads and an explicit class model's precedence" do
    klass = agent_class
    Phronomy.configure { |c| c.default_model = "first" }
    expect(klass.model).to eq("first")
    Phronomy.configure { |c| c.default_model = "second" }
    expect(klass.model).to eq("second")
    klass.model "explicit"
    Phronomy.configure { |c| c.default_model = nil }
    expect(klass.model).to eq("explicit")
  end

  it "copies settings values for nested scopes while retaining injected component identities" do
    adapter = Phronomy.configuration.llm_adapter
    stores = Phronomy::PersistenceComposition.in_memory
    hook = ->(_input) {}
    Phronomy.configure do |c|
      c.default_model = "original"
      c.agent_store = stores.agent
      c.multi_agent_store = stores.multi_agent
      c.workflow_store = stores.workflow
      c.before_llm_input = hook
      c.authorization_timeout = 8
      c.authorization_pool_size = 2
      c.authorization_queue_size = 3
      c.recursion_limit = 12
    end
    expect {
      Phronomy.with_configuration do |outer|
        outer.default_model = "outer"
        outer.agent_store = outer.multi_agent_store = outer.workflow_store = nil
        outer.llm_adapter = outer.before_llm_input = nil
        outer.authorization_timeout = nil
        outer.authorization_pool_size = 7
        outer.authorization_queue_size = 9
        outer.recursion_limit = 4
        expect(Phronomy::Agent::Settings.current.llm_adapter).to be_nil
        expect(Phronomy::MultiAgent::Store.configured).to be_nil
        expect(Phronomy::WorkflowSettings.current.workflow_store).to be_nil
        Phronomy.with_configuration do |inner|
          inner.default_model = "inner"
          inner.recursion_limit = 2
        end
        expect(Phronomy::Agent::Settings.current.default_model).to eq("outer")
        expect(Phronomy::WorkflowSettings.current.recursion_limit).to eq(4)
        raise "scope failed"
      end
    }.to raise_error("scope failed")
    agent = Phronomy::Agent::Settings.current
    expect(agent.default_model).to eq("original")
    expect(agent.llm_adapter).to equal(adapter)
    expect(agent.agent_store).to equal(stores.agent)
    expect(agent.before_llm_input).to equal(hook)
    expect(agent.authorization_timeout).to eq(8)
    expect(Phronomy::MultiAgent::Store.configured).to equal(stores.multi_agent)
    expect(Phronomy::WorkflowSettings.current.workflow_store).to equal(stores.workflow)
    expect(Phronomy::WorkflowSettings.current.recursion_limit).to eq(12)
    expect(Phronomy::RuntimeSettings.current.authorization_pool_size).to eq(2)
    expect(Phronomy::RuntimeSettings.current.authorization_queue_size).to eq(3)
  end

  it "uses fresh defaults after reset without keeping domain settings snapshots" do
    previous = Phronomy::Agent::Settings.current
    Phronomy.configure do |c|
      c.default_model = "changed"
      c.recursion_limit = 3
      c.stream_callback_error_policy = :fail_task
      c.authorization_timeout = nil
    end
    Phronomy.reset_configuration!
    current = Phronomy::Agent::Settings.current
    expect(current).not_to equal(previous)
    expect(current.llm_adapter).not_to equal(previous.llm_adapter)
    expect(current.default_model).to be_nil
    expect(current.stream_callback_error_policy).to eq(:report)
    expect(current.authorization_timeout).to eq(5)
    expect(Phronomy::WorkflowSettings.current.recursion_limit).to eq(25)
    expect(Phronomy::MultiAgent::Store.configured).to be_nil
  end

  it "keeps stream error policy validation and its public exception unchanged" do
    expect { Phronomy.configure { |c| c.stream_callback_error_policy = :unknown } }
      .to raise_error(Phronomy::ConfigurationError, "stream_callback_error_policy must be one of: :report, :fail_task")
    expect(Phronomy::Agent::Settings.current.stream_callback_error_policy).to eq(:report)
  end

  it "reads the global hook when preparing input and retains global/class/instance order" do
    calls = []
    klass = agent_class
    klass.before_llm_input { |_context|
      calls << :class
      nil
    }
    agent = klass.new
    agent.before_llm_input = ->(_context) {
      calls << :instance
      nil
    }
    Phronomy.configure { |c|
      c.before_llm_input = ->(_context) {
        calls << :first
        nil
      }
    }
    agent.send(:run_before_llm_input_hooks, call_sequence: 1, config: {})
    Phronomy.configure { |c|
      c.before_llm_input = ->(_context) {
        calls << :second
        nil
      }
    }
    agent.send(:run_before_llm_input_hooks, call_sequence: 2, config: {})
    expect(calls).to eq(%i[first class instance second class instance])
  end

  it "reads Workflow limits at execution start and leaves an admitted execution unchanged" do
    context = Class.new do
      include Phronomy::WorkflowContext

      field :value, default: ""
    end
    workflow = Phronomy::Workflow.define(context) do
      initial :first
      state :first, action: ->(state) {
        Phronomy.configure { |c| c.recursion_limit = 1 }
        state.merge(value: "first")
      }
      state :second, action: ->(state) { state.merge(value: "second") }
      transition from: :first, to: :second
      transition from: :second, to: :__finish__
    end
    Phronomy.configure { |c| c.recursion_limit = 25 }
    expect(workflow.invoke({}).value).to eq("second")
    expect { workflow.invoke({}) }.to raise_error(Phronomy::RecursionLimitError)
    expect(workflow.invoke({}, config: {recursion_limit: 25}).value).to eq("second")
  end

  it "keeps existing Agent stores and selects new configured stores only for new Agents" do
    first = Phronomy::PersistenceComposition.in_memory.agent
    second = Phronomy::PersistenceComposition.in_memory.agent
    Phronomy.configure { |c| c.agent_store = first }
    agent = agent_class.new
    Phronomy.configure { |c| c.agent_store = second }
    expect(agent.persistence).to equal(first)
    expect(agent_class.new.persistence).to equal(second)
    expect(agent_class.new(persistence: first).persistence).to equal(first)
  end

  it "preserves the different Team and Orchestrator fallback rules" do
    team_class = Class.new(Phronomy::MultiAgent::TeamCoordinator) do
      team_definition id: "settings-team", version: 1
    end
    orchestrator_class = Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "settings-orchestrator", version: 1
    end
    stores = Phronomy::PersistenceComposition.in_memory
    Phronomy.configure { |c| c.multi_agent_store = stores.multi_agent }
    expect(team_class.new.persistence).to equal(stores.multi_agent)
    expect(orchestrator_class.new(persistence: stores.agent).coordination_store).to equal(stores.multi_agent)
    Phronomy.configure { |c| c.multi_agent_store = nil }
    expect(orchestrator_class.new(persistence: stores.agent).coordination_store).to be_nil
    expect(team_class.new.persistence).to be_a(Phronomy::MultiAgent::Store)
    expect(team_class.new(persistence: stores.multi_agent).persistence).to equal(stores.multi_agent)
  end
end
