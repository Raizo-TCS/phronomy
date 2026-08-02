# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      instructions "test"
      model "gpt-4o-mini"
    end
  end
  let(:agent) { agent_class.new }

  describe "#approve EventLoop re-entry guard" do
    it "raises before consuming the pending approval" do
      event_loop = double("event_loop", current?: true)
      runtime = double("runtime", event_loop: event_loop)
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)

      expect(Phronomy::Agent::AgentInvocationRegistry)
        .not_to receive(:consume_approval)

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
    let(:event_loop) { double("event_loop", current?: true) }
    let(:runtime) { double("runtime", event_loop: event_loop) }
    let(:parent_session) { double("parent_session") }
    let(:result) { {output: "resumed", messages: [], usage: nil} }

    before do
      allow(Phronomy::Runtime).to receive(:instance).and_return(runtime)
      allow(Phronomy::Agent::AgentInvocationSessionBuilder)
        .to receive(:build_for_resume)
        .and_return(parent_session)
    end

    def invocation_double(stream_listener: nil)
      double(
        "invocation",
        id: "invocation-1",
        event_listener: stream_listener,
        mode: stream_listener ? :stream : :invoke,
        tool_invocations: []
      ).tap do |invocation|
        allow(invocation).to receive(:merge_config!).and_return(invocation)
        allow(invocation).to receive(:begin_approval_resume!).and_return(invocation)
      end
    end

    def stub_pending_approval(invocation)
      entry = double("registry_entry", invocation: invocation)
      allow(Phronomy::Agent::AgentInvocationRegistry)
        .to receive(:consume_approval)
        .with("invocation-1", "request-1")
        .and_return(entry)
    end

    it "returns immediately with a pending Task" do
      invocation = invocation_double
      stub_pending_approval(invocation)
      source_task = nil

      allow(event_loop).to receive(:register) do |session, completion:|
        expect(session).to be(parent_session)
        source_task = completion
        completion
      end
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(result)

      task = agent.approve_async(
        "invocation-1",
        approval_request_id: "request-1"
      )

      expect(task).to be_a(Phronomy::Task)
      expect(task.done?).to be(false)
      expect(source_task).to be_a(Phronomy::Task)

      source_task.backend.unblock(invocation, nil)
      source_task.transition!(:completed, value: invocation)

      expect(task.wait_result).to eq(result)
    end

    it "is callable while the EventLoop is current" do
      invocation = invocation_double
      stub_pending_approval(invocation)
      source_task = nil

      allow(event_loop).to receive(:register) do |_session, completion:|
        source_task = completion
        completion
      end
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(result)

      expect(event_loop.current?).to be(true)
      task = agent.approve_async(
        "invocation-1",
        approval_request_id: "request-1"
      )

      expect(task).to be_a(Phronomy::Task)
      expect(task.done?).to be(false)

      source_task.backend.unblock(invocation, nil)
      source_task.transition!(:completed, value: invocation)
      expect(task.wait_result).to eq(result)
    end

    it "delivers the resumed stream terminal event on the EventLoop" do
      events = []
      listener = ->(event) { events << [event.type, event_loop.current?] }
      invocation = invocation_double(stream_listener: listener)
      stub_pending_approval(invocation)

      allow(event_loop).to receive(:register) do |_session, completion:|
        completion.backend.unblock(invocation, nil)
        completion.transition!(:completed, value: invocation)
        completion
      end
      allow(agent).to receive(:_extract_invoke_result)
        .with(invocation)
        .and_return(result)

      task = agent.approve_async(
        "invocation-1",
        approval_request_id: "request-1"
      )

      expect(task.wait_result).to eq(result)
      expect(events).to eq([[:done, true]])
    end

    it "returns a failed Task when the approval is no longer pending" do
      allow(Phronomy::Agent::AgentInvocationRegistry)
        .to receive(:consume_approval)
        .and_return(nil)

      task = agent.approve_async(
        "invocation-1",
        approval_request_id: "request-1"
      )

      expect(task).to be_a(Phronomy::Task)
      expect do
        task.wait_result
      end.to raise_error(ArgumentError, /No pending approval/)
    end
  end
end
