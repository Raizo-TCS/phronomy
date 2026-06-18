# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::InvocationSession do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) { model "test-model" }
  end
  let(:agent) { agent_class.new }

  describe ".build" do
    it "returns a Phronomy::FSMSession" do
      session = described_class.build(
        agent: agent,
        input: "hello",
        messages: [],
        config: {thread_id: "t-1"}
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end

    it "uses thread_id from config as session id" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {thread_id: "my-id"}
      )
      expect(session.id).to eq("my-id")
    end

    it "generates a UUID when thread_id is not provided" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {}
      )
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets awaiting_approval as a wait_state" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {}
      )
      wait_states = session.instance_variable_get(:@wait_state_names)
      expect(wait_states).to include(:awaiting_approval)
    end

    it "registers approve and reject as external events" do
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {}
      )
      ext = session.instance_variable_get(:@external_events)
      expect(ext.keys).to include(:approve, :reject)
    end

    it "accepts mode: :stream and on_event" do
      on_event = ->(e) {}
      session = described_class.build(
        agent: agent, input: "hi", messages: [], config: {},
        mode: :stream, on_event: on_event
      )
      expect(session).to be_a(Phronomy::FSMSession)
    end
  end
end
