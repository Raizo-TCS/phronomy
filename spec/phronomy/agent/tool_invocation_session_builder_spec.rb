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
    # Regression: mark_running! must not be called before start_execution
    it "calls start_execution before mark_running! so dispatchable? still holds" do
      invocation = double("invocation", tool_invocations: [], id: "test-inv-1")
      call_order = []

      allow(invocation).to receive(:start_execution).with(runtime: runtime) do |&blk|
        call_order << :start_execution
        blk&.call({status: :completed, result: "ok"})
      end
      allow(invocation).to receive(:mark_running!) do
        call_order << :mark_running
        invocation
      end
      allow(described_class).to receive(:post_to_invocation)

      described_class.send(:running_action, runtime, invocation)

      expect(call_order).to eq([:start_execution, :mark_running])
    end
  end
end
