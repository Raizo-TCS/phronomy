# frozen_string_literal: true

require "spec_helper"

# Minimal stubs for ActiveJob::Base and ActionCable so that the spec
# can load and test AgentJob without a real Rails environment.
unless defined?(::ActiveJob)
  module ActiveJob
    class Base
      class << self
        def queue_as(*)
        end
      end
    end
  end
end

unless defined?(::ActionCable)
  module ActionCable
    class Server
      attr_reader :broadcasts

      def initialize
        @broadcasts = []
      end

      def broadcast(stream, payload)
        @broadcasts << {stream: stream, payload: payload}
      end
    end

    def self.server
      @server ||= Server.new
    end

    def self.reset!
      @server = Server.new
    end
  end
end

require "phronomy/rails/agent_job"

RSpec.describe Phronomy::Rails::AgentJob do
  before { ActionCable.reset! }

  let(:stream_id) { "spec_stream" }

  let(:agent_klass) do
    Class.new(Phronomy::Agent::Base) do
      model "stub-model"
      provider :openai
      instructions "You are helpful."
    end
  end

  def token_event(text)
    Phronomy::Agent::StreamEvent.new(type: :token, payload: {content: text})
  end

  def done_event(text)
    Phronomy::Agent::StreamEvent.new(type: :done,
      payload: {output: text, messages: [], usage: Phronomy::TokenUsage.zero})
  end

  describe "#perform — success" do
    before do
      stub_const("SpecJobAgent", agent_klass)
      allow_any_instance_of(agent_klass).to receive(:stream)
        .and_yield(token_event("Hi"))
        .and_yield(done_event("Hi there!"))
    end

    it "broadcasts a :token payload for each token event" do
      described_class.new.perform(
        "SpecJobAgent", "Hello",
        channel: "AgentChannel", stream: stream_id
      )
      token_broadcasts = ActionCable.server.broadcasts
        .select { |b| b[:payload][:type] == "token" }
      expect(token_broadcasts.size).to eq(1)
      expect(token_broadcasts.first[:payload][:content]).to eq("Hi")
    end

    it "broadcasts a :done payload with the final output" do
      described_class.new.perform(
        "SpecJobAgent", "Hello",
        channel: "AgentChannel", stream: stream_id
      )
      done_broadcast = ActionCable.server.broadcasts
        .find { |b| b[:payload][:type] == "done" }
      expect(done_broadcast[:payload][:output]).to eq("Hi there!")
    end

    it "transforms string config keys to symbols before forwarding" do
      allow_any_instance_of(agent_klass).to receive(:stream) do |_agent, _input, config:, &block|
        # Verify that string keys have been converted.
        expect(config.keys.all? { |k| k.is_a?(Symbol) }).to be true
        block.call(done_event("OK"))
      end

      described_class.new.perform(
        "SpecJobAgent", "Hello",
        channel: "AgentChannel", stream: stream_id,
        config: {"thread_id" => "t1", "user_id" => "u1"}
      )
    end
  end

  describe "#perform — class validation" do
    it "broadcasts :error when agent_class_name is not a valid constant" do
      described_class.new.perform(
        "NonExistentAgentClass99", "Hello",
        channel: "AgentChannel", stream: stream_id
      )
      error_broadcast = ActionCable.server.broadcasts.find { |b| b[:payload][:type] == "error" }
      expect(error_broadcast).not_to be_nil
    end

    it "broadcasts :error when agent_class_name resolves to a non-Agent::Base subclass" do
      stub_const("NotAnAgent", Class.new)
      described_class.new.perform(
        "NotAnAgent", "Hello",
        channel: "AgentChannel", stream: stream_id
      )
      error_broadcast = ActionCable.server.broadcasts.find { |b| b[:payload][:type] == "error" }
      expect(error_broadcast).not_to be_nil
    end
  end

  describe "#perform — error rescue" do
    before { stub_const("SpecJobAgentErr", agent_klass) }

    it "broadcasts an :error payload when the agent raises" do
      allow_any_instance_of(agent_klass).to receive(:stream)
        .and_raise(RuntimeError, "Something went wrong")

      described_class.new.perform(
        "SpecJobAgentErr", "Hello",
        channel: "AgentChannel", stream: stream_id
      )

      error_broadcast = ActionCable.server.broadcasts
        .find { |b| b[:payload][:type] == "error" }
      expect(error_broadcast[:payload][:message]).to eq("Something went wrong")
    end

    it "does not re-raise after broadcasting :error" do
      allow_any_instance_of(agent_klass).to receive(:stream)
        .and_raise(RuntimeError, "fatal")

      expect {
        described_class.new.perform(
          "SpecJobAgentErr", "Hello",
          channel: "AgentChannel", stream: stream_id
        )
      }.not_to raise_error
    end
  end
end
