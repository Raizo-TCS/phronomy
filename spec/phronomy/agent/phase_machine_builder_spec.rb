# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::PhaseMachineBuilder do
  subject(:builder) { described_class.new }

  let(:tracker_class) { builder.build }
  let(:tracker) { tracker_class.new }

  let(:context) do
    Phronomy::Agent::AgentInvocation.new(
      agent: double("agent"),
      input: "x",
      messages: [],
      config: {}
    )
  end

  describe "#build" do
    it "returns a Class initialized to idle" do
      expect(tracker_class).to be_a(Class)
      expect(tracker.phase).to eq("idle")
    end

    it "exposes context and current_event but not async_pending" do
      expect(tracker).to respond_to(:context, :context=)
      expect(tracker).to respond_to(:current_event, :current_event=)
      expect(tracker).not_to respond_to(:async_pending)
    end
  end

  describe "automatic transitions" do
    before { tracker.context = context }

    it "transitions idle to filtering_input" do
      tracker.state_completed
      expect(tracker.phase).to eq("filtering_input")
    end

    it "transitions filtering_input according to filter result" do
      tracker.phase = "filtering_input"
      context.input_blocked = false
      tracker.state_completed
      expect(tracker.phase).to eq("building_context")

      tracker.phase = "filtering_input"
      context.input_blocked = true
      tracker.state_completed
      expect(tracker.phase).to eq("blocked")
    end

    it "transitions building_context to calling_llm" do
      tracker.phase = "building_context"
      tracker.state_completed
      expect(tracker.phase).to eq("calling_llm")
    end

    it "does not expose state_completed from calling_llm" do
      tracker.phase = "calling_llm"
      expect(tracker.state_completed).to be(false)
      expect(tracker.phase).to eq("calling_llm")
    end
  end

  describe "LLM completion events" do
    before do
      tracker.context = context
      tracker.phase = "calling_llm"
    end

    it "transitions llm_completed to starting_tools when calls are pending" do
      context.pending_tool_calls = [double("tool_call")]
      tracker.llm_completed
      expect(tracker.phase).to eq("starting_tools")
    end

    it "transitions llm_completed to output_filtering otherwise" do
      tracker.llm_completed
      expect(tracker.phase).to eq("output_filtering")
    end

    it "transitions llm_failed to failed" do
      tracker.llm_failed
      expect(tracker.phase).to eq("failed")
    end
  end

  describe "tool event transitions" do
    before do
      tracker.context = context
      tracker.phase = "waiting_for_tools"
    end

    Phronomy::Agent::PhaseMachineBuilder::TOOL_EVENTS.each do |event_name|
      it "#{event_name} transitions to evaluating_tools" do
        tracker.public_send(event_name)
        expect(tracker.phase).to eq("evaluating_tools")
      end
    end
  end

  describe "resume" do
    before { tracker.context = context }

    it "transitions suspended to waiting_for_tools" do
      tracker.phase = "suspended"
      tracker.resume
      expect(tracker.phase).to eq("waiting_for_tools")
    end
  end

  describe "entry action validation" do
    it "raises InvalidAsyncEntryActionError when an entry action returns a Task" do
      task_action = ->(_ctx) { Phronomy::Task.deferred(name: "bad-action") }
      klass = described_class.new(
        entry_actions: {filtering_input: [task_action]}
      ).build
      t = klass.new
      t.context = context
      expect { t.state_completed }
        .to raise_error(Phronomy::InvalidAsyncEntryActionError)
    end
  end
end
