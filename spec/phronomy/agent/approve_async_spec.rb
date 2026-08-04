# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-38", version: 1
      instructions "test"
      model "gpt-4o-mini"
    end
  end
  let(:agent) { agent_class.new }

  describe "#approve EventLoop re-entry guard" do
    it "raises SchedulerReentrancyError when called from the EventLoop thread" do
      event_loop = double("event_loop", current?: true)
      runtime = double("runtime", event_loop: event_loop)
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)

      expect do
        agent.approve(
          "invocation-1",
          approval_request_id: "request-1",
          approved: true
        )
      end.to raise_error(
        Phronomy::SchedulerReentrancyError,
        /approve_async/
      )
    end
  end

  describe "#approve_async" do
    it "returns immediately with a pending Task" do
      skip "requires ExecutionCoordinator-based rewrite: approval flow uses ExecutionRepository"
    end

    it "is callable while the EventLoop is current" do
      skip "requires ExecutionCoordinator-based rewrite"
    end

    it "delivers the resumed stream terminal event on the EventLoop" do
      skip "requires ExecutionCoordinator-based rewrite"
    end

    it "returns a failed Task when the approval is no longer pending" do
      skip "requires ExecutionCoordinator-based rewrite"
    end
  end
end
