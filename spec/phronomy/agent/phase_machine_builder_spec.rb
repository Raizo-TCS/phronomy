# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::PhaseMachineBuilder do
  subject(:builder) { described_class.new }

  let(:tracker_class) { builder.build }
  let(:tracker) { tracker_class.new }

  describe "#build" do
    it "returns a Class" do
      expect(tracker_class).to be_a(Class)
    end

    it "initializes to :idle state" do
      expect(tracker.phase).to eq("idle")
    end

    it "exposes attr_accessor :context" do
      expect(tracker).to respond_to(:context)
      expect(tracker).to respond_to(:context=)
    end

    it "exposes attr_accessor :async_pending" do
      expect(tracker).to respond_to(:async_pending)
      expect(tracker).to respond_to(:async_pending=)
    end
  end

  describe "state_completed transitions" do
    let(:ctx) do
      Phronomy::Agent::AgentInvocation.new(
        agent: double("agent"), input: "x", messages: [], config: {}
      )
    end

    before { tracker.context = ctx }

    it "transitions idle → filtering_input" do
      tracker.state_completed
      expect(tracker.phase).to eq("filtering_input")
    end

    it "transitions filtering_input → building_context when input passes" do
      tracker.phase = "filtering_input"
      ctx.input_blocked = false
      tracker.state_completed
      expect(tracker.phase).to eq("building_context")
    end

    it "transitions filtering_input → blocked when input is blocked" do
      tracker.phase = "filtering_input"
      ctx.input_blocked = true
      tracker.state_completed
      expect(tracker.phase).to eq("blocked")
    end

    it "transitions building_context → calling_llm" do
      tracker.phase = "building_context"
      tracker.state_completed
      expect(tracker.phase).to eq("calling_llm")
    end

    it "transitions calling_llm → starting_tools when tool calls are pending" do
      tracker.phase = "calling_llm"
      ctx.pending_tool_calls = [double("tool_call")]
      tracker.state_completed
      expect(tracker.phase).to eq("starting_tools")
    end

    it "transitions calling_llm → output_filtering when no tool calls" do
      tracker.phase = "calling_llm"
      tracker.state_completed
      expect(tracker.phase).to eq("output_filtering")
    end

    it "transitions output_filtering → completed when output passes" do
      tracker.phase = "output_filtering"
      ctx.output_blocked = false
      tracker.state_completed
      expect(tracker.phase).to eq("completed")
    end

    it "transitions output_filtering → blocked when output is blocked" do
      tracker.phase = "output_filtering"
      ctx.output_blocked = true
      tracker.state_completed
      expect(tracker.phase).to eq("blocked")
    end
  end

  describe "tool event transitions" do
    let(:ctx) do
      Phronomy::Agent::AgentInvocation.new(
        agent: double("agent"), input: "x", messages: [], config: {}
      )
    end

    before do
      tracker.context = ctx
      tracker.phase = "waiting_for_tools"
    end

    Phronomy::Agent::PhaseMachineBuilder::TOOL_EVENTS.each do |event_name|
      it "#{event_name} transitions waiting_for_tools → evaluating_tools" do
        tracker.send(event_name)
        expect(tracker.phase).to eq("evaluating_tools")
      end
    end
  end

  describe "external event transitions" do
    let(:ctx) do
      Phronomy::Agent::AgentInvocation.new(
        agent: double("agent"), input: "x", messages: [], config: {}
      )
    end

    before { tracker.context = ctx }

    it "resume transitions suspended → waiting_for_tools" do
      tracker.phase = "suspended"
      tracker.resume
      expect(tracker.phase).to eq("waiting_for_tools")
    end
  end
end
