# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::WorkflowPhaseMachineBuilder do
  let(:context_class) do
    Class.new do
      include Phronomy::WorkflowContext

      field :trace, default: -> { [] }
      field :approved, default: false
      field :fail_action, default: false
      field :count, default: 0
    end
  end

  def build_tracker(first_guard: nil, first_action: nil)
    guard = ->(context, event) {
      context.trace << [:guard, event.payload]
      context.approved
    }
    action = ->(context, event) {
      context.trace << [:action, event.payload]
      raise IOError, "transition failed" if context.fail_action

      context.merge(count: context.count + 1)
    }
    klass = described_class.new(
      entry_point: :preparing,
      declared_states: %i[preparing waiting done],
      wait_state_names: [:waiting],
      external_events: {
        approve: [{from: :waiting, to: :done, event: :approve, guard: guard, action: action}],
        retry: [{from: :waiting, to: :waiting, event: :retry, action: action}]
      },
      entry_actions: {done: [->(context) { context.trace << :entry }]},
      auto_transitions: [
        {from: :preparing, to: :waiting, event: :state_completed, guard: first_guard, action: first_action},
        {from: :done, to: Phronomy::Workflow::Completion::FINISH, event: :state_completed}
      ],
      exit_actions: {waiting: [->(context) { context.trace << :exit }]}
    ).build
    klass.new.tap { |tracker| tracker.context = context_class.new }
  end

  # The dependency's original named helpers remain in an included module.
  # Invoke them directly as a behavioral reference for the compiled wrappers.
  def original_event(tracker, name, *args, **kwargs)
    owner = tracker.class.ancestors.drop(1).find { |ancestor| ancestor.method_defined?(name, false) }
    raise "Dependency event helper not found: #{name}" unless owner

    owner.instance_method(name).bind_call(tracker, *args, **kwargs)
  end

  def fire(tracker, name, original: false, args: [], kwargs: {})
    tracker.current_event = Phronomy::Event.new(type: name, target_id: "dispatch-test", payload: {answer: 7})
    original ? original_event(tracker, name, *args, **kwargs) : tracker.public_send(name, *args, **kwargs)
  end

  def result_shape(result)
    return result if result == true || result == false

    [result.class, result.event, result.from, result.to]
  end

  it "executes compiled automatic transitions without redefining their states" do
    tracker = build_tracker
    machine = tracker.class.state_machines.fetch(:phase)
    allow(machine).to receive(:event).and_call_original
    expect(machine).not_to receive(:event).with(:state_completed)

    expect(fire(tracker, :state_completed)).to be_truthy
    expect(tracker.phase).to eq("waiting")
    expect(fire(tracker, :approve)).to be(false)
    expect(tracker.phase).to eq("waiting")
    tracker.context = tracker.context.merge(approved: true)
    expect(fire(tracker, :approve)).to be_truthy
    expect(tracker.phase).to eq("done")
    expect(fire(tracker, :state_completed)).to be_truthy
    expect(tracker.phase).to eq(Phronomy::FSMProtocol::FINISH.to_s)
    expect(tracker.context.count).to eq(1)
  end

  it "preserves guard refusal, callback ordering, adopted context and success return shapes" do
    outcomes = [false, true].map do |original|
      tracker = build_tracker
      returns = [result_shape(fire(tracker, :state_completed, original: original))]
      returns << result_shape(fire(tracker, :approve, original: original))
      refused_phase = tracker.phase
      tracker.context = tracker.context.merge(approved: true)
      old_context = tracker.context
      returns << result_shape(fire(tracker, :approve, original: original))
      expect(tracker.context).not_to be(old_context)
      [returns, refused_phase, tracker.phase, tracker.context.count, tracker.context.trace]
    end

    expect(outcomes.first).to eq(outcomes.last)
    expect(outcomes.first[1..3]).to eq(["waiting", "done", 1])
    expect(outcomes.first.last).to eq([
      [:guard, {answer: 7}], [:guard, {answer: 7}], :exit, [:action, {answer: 7}], :entry
    ])
  end

  it "preserves loopback callbacks and subsequent progress" do
    outcomes = [false, true].map do |original|
      tracker = build_tracker
      fire(tracker, :state_completed, original: original)
      result = fire(tracker, :retry, original: original)
      [result_shape(result), tracker.phase, tracker.context.count, tracker.context.trace]
    end

    expect(outcomes.first).to eq(outcomes.last)
    expect(outcomes.first[1..]).to eq(["waiting", 1, [:exit, [:action, {answer: 7}]]])
  end

  it "retains automatic guard refusal without running the action" do
    [false, true].each do |original|
      calls = []
      tracker = build_tracker(
        first_guard: ->(_context) {
          calls << :guard
          false
        },
        first_action: ->(_context) { calls << :action }
      )
      expect(fire(tracker, :state_completed, original: original)).to be(false)
      expect(tracker.phase).to eq("preparing")
      expect(calls).to eq([:guard])
    end
  end

  %i[first_guard first_action].each do |callback|
    it "propagates the original automatic #{callback} exception" do
      [false, true].each do |original|
        error = IOError.new("callback failed")
        tracker = build_tracker(**{callback => ->(_context) { raise error }})
        expect { fire(tracker, :state_completed, original: original) }.to raise_error(IOError) { |raised|
          expect(raised).to be(error)
        }
        expect(tracker.phase).to eq("preparing")
        expect(tracker.context.trace).to be_empty
      end
    end
  end

  it "propagates the same action error before target entry and state publication" do
    outcomes = [false, true].map do |original|
      tracker = build_tracker
      fire(tracker, :state_completed, original: original)
      tracker.context = tracker.context.merge(approved: true, fail_action: true)
      expect { fire(tracker, :approve, original: original) }.to raise_error(IOError, "transition failed")
      [tracker.phase, tracker.context.count, tracker.context.trace]
    end

    expect(outcomes.first).to eq(outcomes.last)
    expect(outcomes.first).to eq(["waiting", 0, [[:guard, {answer: 7}], :exit, [:action, {answer: 7}]]])
  end

  [
    {args: ["request", {source: "client"}], kwargs: {}},
    {args: ["request"], kwargs: {source: "client"}},
    {args: [false], kwargs: {}}
  ].each do |arguments|
    it "preserves dependency event arguments #{arguments.inspect}" do
      outcomes = [false, true].map do |original|
        tracker = build_tracker
        observed = []
        tracker.class.state_machines.fetch(:phase).after_transition do |_object, transition|
          observed << transition.args
        end
        result = fire(tracker, :state_completed, original: original, **arguments)
        [result_shape(result), tracker.phase, observed]
      end
      expect(outcomes.first).to eq(outcomes.last)
      expect(outcomes.first[1]).to eq("waiting")
      expect(outcomes.first.last.length).to eq(1)
    end
  end

  it "retains bang-method refusal behavior" do
    tracker = build_tracker
    fire(tracker, :state_completed)
    tracker.current_event = Phronomy::Event.new(type: :state_completed, target_id: "dispatch-test", payload: {})

    expect { tracker.state_completed! }.to raise_error(StateMachines::InvalidTransition)
    expect(tracker.phase).to eq("waiting")
  end

  it "lets a subclass event override delegate to the compiled dispatch" do
    subclass = Class.new(build_tracker.class) do
      def state_completed(*args, **kwargs)
        context.trace << :override
        super
      end
    end
    tracker = subclass.new
    tracker.context = context_class.new

    expect(fire(tracker, :state_completed)).to be_truthy
    expect(tracker.phase).to eq("waiting")
    expect(tracker.context.trace).to eq([:override])
  end

  it "resolves the subclass machine instead of capturing its parent's event" do
    parent = build_tracker
    subclass = Class.new(parent.class) do
      state_machine :phase do
        event :state_completed do
          transition waiting: :done
        end
      end
    end
    child = subclass.new
    child.context = context_class.new
    parent.phase = "waiting"
    child.phase = "waiting"

    expect(fire(parent, :state_completed)).to be(false)
    expect(fire(child, :state_completed)).to be_truthy
    expect(parent.phase).to eq("waiting")
    expect(child.phase).to eq("done")
  end
end
