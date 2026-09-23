# frozen_string_literal: true

require "spec_helper"

RSpec.describe "FSMSession terminal policy contract" do
  let(:events) { [] }
  let(:notifications) { [] }
  let(:requests) { [] }
  let(:context) { Object.new }
  let(:event_loop) { double("EventLoop") }
  let(:policy) { double("Domain terminal policy") }
  let(:machine_class) { Class.new { attr_accessor :context } }

  before do
    allow(event_loop).to receive(:post) { |event|
      events << event
      true
    }
    allow(policy).to receive(:start) { |**request| requests << request }
    allow(policy).to receive(:handles?) { |event| event.type == :domain_decision }
    allow(policy).to receive(:decision_for) { |event| event.payload }
  end

  def session_with(policy: self.policy)
    Phronomy::FSMSession.new(
      context: context, entry_point: :leaf, entry_actions: {},
      auto_state_set: {}, declared_states: [:leaf], wait_state_names: [],
      external_events: {}, phase_machine_class: machine_class,
      recursion_limit: 10, event_loop: event_loop,
      stable_observer: ->(event) { notifications << event },
      terminal_policy: policy
    )
  end

  def decide(session, action, error: nil)
    session.handle(Phronomy::Event.new(
      type: :domain_decision, target_id: session.id,
      payload: Phronomy::FSMProtocol::TerminalDecision.new(action: action, error: error)
    ))
  end

  it "accepts one requested domain decision and ignores early, ordinary and duplicate events" do
    session = session_with
    expect(policy).to receive(:decision_for).once { |event| event.payload }
    decide(session, :complete)
    expect(events).to be_empty
    session.start
    expect(requests.size).to eq(1)
    expect(requests.first).to eq(terminal_type: :finished, context: context, event_sink: session.event_sink)
    expect(session.event_sink.fsm_session_id).to eq(session.id)
    session.handle(Phronomy::Event.new(type: :ordinary, target_id: session.id, payload: nil))
    expect(events).to be_empty
    expect(notifications).to be_empty

    decide(session, :complete)
    decide(session, :fail, error: RuntimeError.new("late"))
    expect(events.map(&:type)).to eq([:finished])
    expect(events.first.payload).to eq(fsm_session_id: session.id, result: context)
    expect(notifications).to eq([{state: :leaf, context: context}])
  end

  it "preserves the error supplied by a policy without notifying success" do
    session = session_with
    session.start
    original = RuntimeError.new("domain failed")
    decide(session, :fail, error: original)
    expect(events.map(&:type)).to eq([:error])
    expect(events.first.payload[:result]).to equal(original)
    expect(notifications).to be_empty
  end

  it "retires without publishing a successful result or an ordinary failure" do
    session = session_with
    session.start
    original = IOError.new("domain unresolved")
    decide(session, :retire, error: original)
    decide(session, :complete)
    expect(events.map(&:type)).to eq([:recovery_required])
    expect(events.first.payload).to eq(fsm_session_id: session.id, error: original)
    expect(notifications).to be_empty
  end

  it "uses the existing failure path when starting the policy raises" do
    original = RuntimeError.new("submission failed")
    allow(policy).to receive(:start).and_raise(original)
    session_with.start
    expect(events.map(&:type)).to eq([:error])
    expect(events.first.payload[:result]).to equal(original)
    expect(notifications).to be_empty
  end

  it "fails a malformed private policy decision instead of stranding the session" do
    session = session_with
    session.start
    decide(session, :unsupported)
    expect(events.map(&:type)).to eq([:error])
    expect(events.first.payload[:result]).to be_a(Phronomy::Error)
    expect(events.first.payload[:result].message).to include("unknown FSM terminal decision")
  end

  it "completes immediately without a domain policy" do
    session_with(policy: nil).start
    expect(events.map(&:type)).to eq([:finished])
    expect(notifications).to eq([{state: :leaf, context: context}])
    expect(requests).to be_empty
  end
end
