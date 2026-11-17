# frozen_string_literal: true

require "phronomy/engine/fsm_protocol"
require "phronomy/workflow/completion"
require "phronomy/workflow/runtime_binding/workflow_phase_machine_builder"

RSpec.describe Phronomy::WorkflowPhaseMachineBuilder, "transition state names" do
  %i[before after around do].each do |state_name|
    %i[state_completed advance].each do |event_name|
      it "preserves guarded #{event_name} transitions from #{state_name}" do
        transition = {
          from: state_name,
          to: :nested,
          event: event_name,
          guard: ->(context) { context.fetch(:approved) }
        }
        automatic = event_name == :state_completed
        tracker = described_class.new(
          entry_point: state_name,
          declared_states: [state_name, :nested],
          wait_state_names: [],
          external_events: automatic ? {} : {event_name => [transition]},
          entry_actions: {},
          auto_transitions: automatic ? [transition] : [],
          exit_actions: {}
        ).build.new
        tracker.context = {approved: false}

        expect(tracker.public_send(event_name)).to be(false)
        expect(tracker.phase).to eq(state_name.to_s)

        tracker.context[:approved] = true
        expect(tracker.public_send(event_name)).to be_truthy
        expect(tracker.phase).to eq("nested")
      end
    end
  end
end
