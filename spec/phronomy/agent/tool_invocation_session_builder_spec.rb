# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ToolInvocationSessionBuilder do
  let(:runtime) { Phronomy::Runtime.instance }

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe ".running_action" do
    # Regression: execution_task checks dispatchable? which requires :queued
    # status. mark_running! must not be called before execution_task starts.
    it "calls execution_task before mark_running! so dispatchable? still holds" do
      task = Phronomy::Task.deferred(name: "tool-execution-stub")
      invocation = double("invocation", tool_invocations: [])

      expect(invocation)
        .to receive(:execution_task)
        .with(runtime: runtime)
        .ordered
        .and_return(task)
      expect(invocation)
        .to receive(:mark_running!)
        .ordered
      expect(described_class)
        .to receive(:observe_task)
        .with(runtime, invocation, task, event_type: :execution_completed)

      described_class.send(:running_action, runtime, invocation)
    end
  end
end
