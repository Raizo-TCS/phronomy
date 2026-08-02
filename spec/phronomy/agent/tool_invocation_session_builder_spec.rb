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
      call_order = []
      task = Phronomy::Task.deferred(name: "tool-execution-stub")
      invocation = double("invocation", tool_invocations: [])

      allow(invocation).to receive(:execution_task).ordered do
        call_order << :execution_task
        task
      end
      allow(invocation).to receive(:mark_running!).ordered do
        call_order << :mark_running!
      end
      allow(invocation).to receive(:id).and_return("test-invocation-1")
      allow(described_class).to receive(:observe_task)

      described_class.send(:running_action, runtime, invocation)

      expect(call_order).to eq([:execution_task, :mark_running!])
    end
  end
end
