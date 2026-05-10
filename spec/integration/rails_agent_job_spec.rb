# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 27: Rails WebSocket Agent Job
# Pairwise factors: job_agent_type × job_error_scenario × job_config_style
# Generated stubs: 4 cases — all feasible
#
# LLM required: No (WebMock)
#
# Strategy: Simulate ActiveJob::Base and ActionCable without a real Rails
#           environment, then load AgentJob, call #perform directly, and
#           assert on what was broadcast.

# ---------------------------------------------------------------------------
# Minimal stubs for Rails dependencies (ActiveJob::Base, ActionCable)
# ---------------------------------------------------------------------------
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

RSpec.describe "Group 27: Rails WebSocket Agent Job", :integration do
  before do
    ActionCable.reset!
    @llm = LLMStub.activate(responses: ["Hello, I can help!"])
  end

  after { LLMStub.deactivate }

  let(:stream_id) { "test_stream_27" }

  # Helper: builds StreamEvent objects for success stubs.
  def token_event(text)
    Phronomy::Agent::StreamEvent.new(type: :token, payload: {content: text})
  end

  def done_event(text)
    Phronomy::Agent::StreamEvent.new(type: :done,
      payload: {output: text, messages: [], usage: Phronomy::TokenUsage.zero})
  end

  # ---------------------------------------------------------------------------
  # TC-001: base / no_error / symbol_keys
  #         Base agent; succeeds; config uses symbol keys.
  # ---------------------------------------------------------------------------
  describe "TC-001: base agent; no error; symbol config keys" do
    it "broadcasts :token and :done events to ActionCable stream" do
      klass = IntegrationFactors.job_agent_class("base")
      stub_const("TC001Agent27", klass)

      allow_any_instance_of(klass).to receive(:stream)
        .and_yield(token_event("Hello"))
        .and_yield(done_event("Hello, I can help!"))

      config = IntegrationFactors.job_config("symbol_keys")
      job = Phronomy::Rails::AgentJob.new
      job.perform("TC001Agent27", "Hello", channel: "AgentChannel", stream: stream_id, config: config)

      broadcasts = ActionCable.server.broadcasts.select { |b| b[:stream] == stream_id }
      types = broadcasts.map { |b| b[:payload][:type] }
      expect(types).to include("token", "done")
      done_payload = broadcasts.find { |b| b[:payload][:type] == "done" }
      expect(done_payload[:payload][:output]).to eq("Hello, I can help!")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: base / agent_error / string_keys
  #         Base agent raises; job broadcasts :error; string config keys.
  # ---------------------------------------------------------------------------
  describe "TC-002: base agent; agent raises; string config keys" do
    it "broadcasts :error event when agent raises" do
      klass = IntegrationFactors.job_agent_class("base")
      stub_const("TC002Agent27", klass)

      allow_any_instance_of(klass).to receive(:stream).and_raise(RuntimeError, "LLM timeout")

      config = IntegrationFactors.job_config("string_keys")
      job = Phronomy::Rails::AgentJob.new
      job.perform("TC002Agent27", "Hello", channel: "AgentChannel", stream: stream_id, config: config)

      broadcasts = ActionCable.server.broadcasts.select { |b| b[:stream] == stream_id }
      expect(broadcasts.size).to eq(1)
      expect(broadcasts.first[:payload][:type]).to eq("error")
      expect(broadcasts.first[:payload][:message]).to eq("LLM timeout")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: react / no_error / string_keys
  #         ReactAgent; succeeds; string config keys transformed to symbols.
  # ---------------------------------------------------------------------------
  describe "TC-003: react agent; no error; string config keys" do
    it "broadcasts :token and :done events; string keys are accepted" do
      klass = IntegrationFactors.job_agent_class("react")
      stub_const("TC003Agent27", klass)

      allow_any_instance_of(klass).to receive(:stream)
        .and_yield(token_event("Sure!"))
        .and_yield(done_event("Sure, I can help!"))

      config = IntegrationFactors.job_config("string_keys")
      job = Phronomy::Rails::AgentJob.new
      job.perform("TC003Agent27", "Hello", channel: "AgentChannel", stream: stream_id, config: config)

      broadcasts = ActionCable.server.broadcasts.select { |b| b[:stream] == stream_id }
      types = broadcasts.map { |b| b[:payload][:type] }
      expect(types).to include("token", "done")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: react / agent_error / symbol_keys
  #         ReactAgent raises; job broadcasts :error; symbol config keys.
  # ---------------------------------------------------------------------------
  describe "TC-004: react agent; agent raises; symbol config keys" do
    it "broadcasts :error event when react agent raises" do
      klass = IntegrationFactors.job_agent_class("react")
      stub_const("TC004Agent27", klass)

      allow_any_instance_of(klass).to receive(:stream).and_raise(RuntimeError, "Connection refused")

      config = IntegrationFactors.job_config("symbol_keys")
      job = Phronomy::Rails::AgentJob.new
      job.perform("TC004Agent27", "Hello", channel: "AgentChannel", stream: stream_id, config: config)

      broadcasts = ActionCable.server.broadcasts.select { |b| b[:stream] == stream_id }
      expect(broadcasts.size).to eq(1)
      expect(broadcasts.first[:payload][:type]).to eq("error")
      expect(broadcasts.first[:payload][:message]).to eq("Connection refused")
    end
  end
end
