# frozen_string_literal: true

require "spec_helper"

RSpec.describe "FSMSession generic recursion limit scopes" do
  def session(scope: :automatic_chain, looping: false)
    events = []
    loop_object = Object.new
    loop_object.define_singleton_method(:post) { |e|
      events << e
      true
    }
    machine = Class.new do
      attr_accessor :context, :current_event
      def phase = @phase.to_sym

      def state_completed
        @phase = context.fetch(:looping) ? "automatic" : "waiting"
        true
      end

      def ready
        return false unless phase == :waiting
        @phase = "automatic"
        true
      end

      def ignored = false
    end
    ctx = {looping: looping}
    ctx.define_singleton_method(:handle_fsm_event) { |e| (e.type == :stale) ? :consume : false }
    value = Phronomy::FSMSession.new(context: ctx, entry_point: :automatic,
      entry_actions: {}, auto_state_set: {automatic: true}, declared_states: %i[automatic waiting],
      wait_state_names: [], external_events: {ready: [{from: :waiting}], ignored: [{from: :automatic}]},
      phase_machine_class: machine, recursion_limit: 2, recursion_limit_scope: scope,
      event_loop: loop_object)
    [value, events]
  end

  def fire(value, type)
    value.handle(Phronomy::Event.new(type: type, target_id: value.id, payload: nil))
  end

  it "bounds automatic chains while allowing repeated external progress" do
    value, events = session
    value.start
    10.times {
      fire(value, :state_completed)
      fire(value, :ready)
    }
    expect(events.none? { |e| e.type == :error }).to be(true)
    expect(value.instance_variable_get(:@step)).to eq(20)
  end

  it "still stops an infinite automatic loop" do
    value, events = session(looping: true)
    value.start
    3.times { fire(value, :state_completed) }
    error = events.find { |e| e.type == :error }.payload.fetch(:result)
    expect(error).to be_a(Phronomy::RecursionLimitError)
    expect(value.instance_variable_get(:@step)).to eq(2)
  end

  it "does not reset a chain for consumed or non-transitioning external events" do
    value, events = session(looping: true)
    value.start
    2.times { fire(value, :state_completed) }
    fire(value, :stale)
    fire(value, :ignored)
    fire(value, :state_completed)
    expect(events.find { |e| e.type == :error }.payload.fetch(:result)).to be_a(Phronomy::RecursionLimitError)
  end

  it "retains the existing total-transition limit in session scope" do
    value, events = session(scope: :session)
    value.start
    fire(value, :state_completed)
    fire(value, :ready)
    fire(value, :state_completed)
    expect(events.find { |e| e.type == :error }.payload.fetch(:result)).to be_a(Phronomy::RecursionLimitError)
    expect(value.instance_variable_get(:@step)).to eq(2)
  end

  it "rejects an unknown scope" do
    expect { session(scope: :llm_turns) }.to raise_error(ArgumentError, /recursion_limit_scope/)
  end
end
