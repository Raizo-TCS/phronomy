# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "Agent Tool child progress contract" do
  let(:policy) { Phronomy::Agent::ToolInvocationTransitions }
  let(:machine_class) { Phronomy::Agent::PhaseMachineBuilder.new(transitions: policy).build }

  [
    [:authorizing, :authorization_completed,
      %i[cancelled? failed? rejected? awaiting_approval? authorized?],
      %i[cancelled failed rejected awaiting_approval authorized]],
    [:running, :execution_completed,
      %i[cancelled? failed? execution_completed?], %i[cancelled failed completed]],
    [:validating, :state_completed,
      %i[failed? validation_completed? validation_passed?], %i[failed completed authorizing]]
  ].each do |source, event, guards, targets|
    (2**guards.length).times do |mask|
      it "preserves #{event} priority and short circuiting for mask #{mask}" do
        calls = []
        context = Object.new
        guards.each_with_index do |guard, index|
          context.define_singleton_method(guard) do
            calls << guard
            mask[index] == 1
          end
        end
        first = (0...guards.length).find { |index| mask[index] == 1 }
        expected = first && targets[first]
        expect(policy.next_phase(source, event, context)).to eq(expected)
        expect(calls).to eq(guards.take(first ? first + 1 : guards.length))
        calls.clear
        machine = machine_class.new
        machine.context = context
        machine.phase = source.to_s
        expect(machine.public_send(event)).to eq(!expected.nil?)
        expect(machine.phase.to_sym).to eq(expected || source)
        expect(calls).to eq(guards.take(first ? first + 1 : guards.length))
      end
    end
  end

  it "admits approval, dispatch and cancellation only from their legal sources" do
    expected = {
      approve: {awaiting_approval: :authorized},
      reject: {awaiting_approval: :rejected},
      dispatch: {authorized: :queued},
      cancel: %i[awaiting_approval authorized queued running].to_h { |s| [s, :cancelled] }
    }
    states = %i[idle validating authorizing awaiting_approval authorized queued running completed failed rejected cancelled]
    expected.each do |event, transitions|
      states.each do |source|
        target = transitions[source]
        expect(policy.next_phase(source, event, nil)).to eq(target)
        machine = machine_class.new
        machine.phase = source.to_s
        expect(machine.public_send(event)).to eq(!target.nil?)
        expect(machine.phase.to_sym).to eq(target || source)
      end
    end
  end

  it "evaluates child progress without loading Engine or the FSM library" do
    source = <<~RUBY
      require "phronomy/agent/tool_execution/tool_invocation_transitions"
      policy = Phronomy::Agent::ToolInvocationTransitions
      abort unless policy.next_phase(:idle, :state_completed, nil) == :validating
      abort unless policy.next_phase(:awaiting_approval, :approve, nil) == :authorized
      abort unless policy.next_phase(:completed, :dispatch, nil).nil?
      abort if defined?(Phronomy::Runtime) || defined?(Phronomy::FSMSession) || defined?(StateMachines)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", source)
    expect(status.success?).to be(true), output
  end

  it "propagates a guard exception without advancing the child" do
    error = RuntimeError.new("authorization guard failed")
    context = double("context")
    allow(context).to receive(:cancelled?).and_raise(error)
    machine = machine_class.new
    machine.context = context
    machine.phase = "authorizing"
    expect { machine.authorization_completed }.to raise_error { |raised| expect(raised).to be(error) }
    expect(machine.phase).to eq("authorizing")
  end

  it "keeps source admission and FSM construction on the same immutable transition definition" do
    environment = Phronomy::Agent::EngineEnvironment.new(runtime: double("runtime", event_loop: double("loop")))
    allow(Phronomy::Agent::ToolInvocationActions).to receive(:build_entry_actions).and_return({})
    session = environment.build_tool_session(invocation: Object.new, parent_sink: Object.new)
    expect(session.instance_variable_get(:@external_events)).to eq(policy::EXTERNAL_EVENTS)
    policy::EVENTS.each_value do |definitions|
      expect(definitions).to be_frozen
      expect(definitions).to all(be_frozen)
    end
  end
end
