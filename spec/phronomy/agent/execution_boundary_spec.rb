# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "Agent-owned execution boundary" do
  it "executes transition policy without loading Engine or state_machines" do
    source = <<~CODE
      require "phronomy/agent/execution/invocation_transitions"
      policy = Phronomy::Agent::InvocationTransitions
      abort unless policy.next_phase(:idle, :state_completed, nil) == :filtering_input
      abort if defined?(Phronomy::Runtime) || defined?(Phronomy::FSMSession) || defined?(StateMachines)
      abort unless policy.next_phase(:completed, :llm_completed, nil).nil?
      puts "standalone policy passed"
    CODE
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status.success?).to be(true), output
  end

  32.times do |mask|
    it "preserves ordered Tool outcome priority for condition mask #{mask}" do
      guards = %i[tool_batch_failed? tool_batch_rejected? tool_batch_completed? approval_required? ready_to_dispatch?]
      calls = []
      context = Object.new
      guards.each_with_index do |guard, index|
        context.define_singleton_method(guard) {
          calls << guard
          mask[index] == 1
        }
      end
      first = (0...5).find { |index| mask[index] == 1 }
      expected = %i[failed blocked recording_tool_results suspended dispatching_tools waiting_for_tools][first || 5]
      policy = Phronomy::Agent::InvocationTransitions
      expect(policy.next_phase(:evaluating_tools, :state_completed, context)).to eq(expected)
      expect(calls).to eq(guards.take((first || 4) + 1))
      calls.clear
      machine = Phronomy::Agent::PhaseMachineBuilder.new.build.new
      machine.context = context
      machine.phase = "evaluating_tools"
      expect(machine.state_completed).to be(true)
      expect(machine.phase.to_sym).to eq(expected)
      expect(calls).to eq(guards.take((first || 4) + 1))
    end
  end

  it "keeps an Agent bound to its original environment when composition changes" do
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "environment-owner", version: 1
    end
    original = Phronomy::Agent::ExecutionEnvironment.current
    Phronomy::Agent::ExecutionEnvironment.install_provider(-> { original })
    agent = klass.new
    other_runtime = Phronomy::Runtime.new
    other = Phronomy::Agent::EngineEnvironment.new(runtime: other_runtime)
    Phronomy::Agent::ExecutionEnvironment.install_provider(-> { other })
    expect(agent.__execution_environment).to be(original)
    expect(other_runtime.__event_loop_if_initialized).to be_nil
    expect(other.existing_ownership).to be_nil
  ensure
    Phronomy::Agent::ExecutionEnvironment.install_provider(-> { Phronomy::Agent::EngineEnvironment.new })
    other_runtime&.shutdown
  end

  it "delivers cancellation through the originating environment after composition changes" do
    registry = double("origin registry")
    environment = double("origin environment", registry: registry)
    token = Phronomy::Concurrency::CancellationToken.new
    state = double("state", agent: double("agent", agent_id: "agent-1"), invocation: double("invocation", config: {cancellation_token: token}))
    allow(registry).to receive(:agent_execution_state).with("execution-1").and_return(state)
    allow(registry).to receive(:post) { |command| command.coordinator.deliver_on_event_loop(command) }
    expect(Phronomy::Agent::ExecutionEnvironment).not_to receive(:current)
    Phronomy::Agent::ExecutionCancellation.signal("execution-1", "agent-1", environment: environment)
    expect(token).to be_cancelled
  end

  it "does not deliver cancellation to a different Agent owner" do
    registry = double("registry")
    environment = double("environment", registry: registry)
    token = Phronomy::Concurrency::CancellationToken.new
    state = double("state", agent: double("agent", agent_id: "other-agent"), invocation: double("invocation", config: {cancellation_token: token}))
    allow(registry).to receive(:agent_execution_state).and_return(state)
    allow(registry).to receive(:post) { |command| command.coordinator.deliver_on_event_loop(command) }
    Phronomy::Agent::ExecutionCancellation.signal("execution-1", "agent-1", environment: environment)
    expect(token).not_to be_cancelled
  end
end
