# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "FSM dependency contract" do
  it "loads the session and compiles a terminal transition without a WorkflowRunner definition" do
    source = <<~RUBY
      require "phronomy/engine/fsm_protocol"
      require "phronomy/engine/fsm_session"
      require "phronomy/workflow/phase_machine_builder"

      builder = Phronomy::Workflow::PhaseMachineBuilder.new(
        entry_point: :start,
        declared_states: [:start],
        wait_state_names: [],
        external_events: {},
        entry_actions: {},
        exit_actions: {},
        auto_transitions: [
          {from: :start, to: Phronomy::FSMProtocol::FINISH}
        ]
      )
      machine = builder.build.new
      machine.state_completed

      abort "FSM did not reach its terminal state" unless machine.phase.to_sym == :__end__
      abort "FSM components loaded WorkflowRunner" if Phronomy.const_defined?(:WorkflowRunner, false)
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", source
    )

    expect(status.success?).to be(true), [stdout, stderr].join("\n")
  end
end
