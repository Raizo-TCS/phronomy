# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::CancellationToken do
  describe "#initialize" do
    it "starts in the non-cancelled state" do
      expect(described_class.new.cancelled?).to be false
    end

    it "accepts an optional deadline" do
      deadline = Time.now + 60
      token = described_class.new(deadline: deadline)
      expect(token.deadline).to eq(deadline)
    end

    it "returns nil deadline when none is provided" do
      expect(described_class.new.deadline).to be_nil
    end
  end

  describe "#cancel!" do
    it "transitions the token to cancelled" do
      token = described_class.new
      token.cancel!
      expect(token.cancelled?).to be true
    end

    it "returns self for chaining" do
      token = described_class.new
      expect(token.cancel!).to be token
    end

    it "is idempotent — calling cancel! multiple times is safe" do
      token = described_class.new
      token.cancel!
      token.cancel!
      expect(token.cancelled?).to be true
    end
  end

  describe "#cancelled?" do
    it "returns false for a fresh token with no deadline" do
      expect(described_class.new.cancelled?).to be false
    end

    it "returns true after cancel! is called" do
      token = described_class.new
      token.cancel!
      expect(token.cancelled?).to be true
    end

    it "returns false when the deadline is in the future" do
      token = described_class.new(deadline: Time.now + 3600)
      expect(token.cancelled?).to be false
    end

    it "returns true when the deadline has passed" do
      token = described_class.new(deadline: Time.now - 1)
      expect(token.cancelled?).to be true
    end

    it "is thread-safe — concurrent cancel!/cancelled? calls do not raise" do
      token = described_class.new
      threads = 10.times.map { Thread.new { token.cancel! } } +
        10.times.map { Thread.new { token.cancelled? } }
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe ".timeout_after" do
    it "returns a CancellationToken" do
      expect(described_class.timeout_after(60)).to be_a(described_class)
    end

    it "is not cancelled immediately for a positive duration" do
      token = described_class.timeout_after(60)
      expect(token.cancelled?).to be false
    end

    it "is cancelled when the duration has elapsed (monotonic clock)" do
      token = described_class.timeout_after(-1)
      expect(token.cancelled?).to be true
    end

    it "has a nil wall-clock deadline (uses monotonic clock internally)" do
      token = described_class.timeout_after(60)
      expect(token.deadline).to be_nil
    end

    it "can still be explicitly cancelled before the timeout elapses" do
      token = described_class.timeout_after(60)
      token.cancel!
      expect(token.cancelled?).to be true
    end
  end

  describe "#raise_if_cancelled!" do
    it "returns nil when not cancelled" do
      token = described_class.new
      expect(token.raise_if_cancelled!).to be_nil
    end

    it "raises CancellationError when explicitly cancelled" do
      token = described_class.new
      token.cancel!
      expect { token.raise_if_cancelled! }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError with the default message" do
      token = described_class.new
      token.cancel!
      expect { token.raise_if_cancelled! }.to raise_error(Phronomy::CancellationError, "invocation cancelled")
    end

    it "raises CancellationError with a custom message" do
      token = described_class.new
      token.cancel!
      expect { token.raise_if_cancelled!("stopped during RAG") }.to raise_error(Phronomy::CancellationError, "stopped during RAG")
    end

    it "raises CancellationError when deadline-expired (timeout_after)" do
      token = described_class.timeout_after(-1)
      expect { token.raise_if_cancelled! }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "Agent::Base integration" do
    # A bare agent class with no invoke override. Cancellation is checked
    # in _invoke_impl before invoke_once (and thus the LLM) is called.
    let(:bare_agent_class) { Class.new(Phronomy::Agent::Base) }

    # An agent that short-circuits invoke to avoid real LLM calls.
    let(:success_agent_class) do
      Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, messages: [], thread_id: nil, config: {}|
          {output: "ok", messages: []}
        end
      end
    end

    it "raises CancellationError when the token is already cancelled at invoke time" do
      token = described_class.new
      token.cancel!

      expect {
        bare_agent_class.new.invoke("hello", config: {cancellation_token: token})
      }.to raise_error(Phronomy::CancellationError)
    end

    it "does not raise CancellationError when the token is not cancelled" do
      token = described_class.new

      result = success_agent_class.new.invoke("hello", config: {cancellation_token: token})
      expect(result[:output]).to eq("ok")
    end

    it "raises CancellationError for a deadline-expired token" do
      token = described_class.new(deadline: Time.now - 1)

      expect {
        bare_agent_class.new.invoke("hello", config: {cancellation_token: token})
      }.to raise_error(Phronomy::CancellationError)
    end

    it "does not retry after CancellationError even when retry_policy is set" do
      call_count = 0
      retry_agent = Class.new(Phronomy::Agent::Base) do
        retry_policy times: 3, wait: 0
        define_method(:invoke_once) do |_input, messages: [], thread_id: nil, config: {}|
          call_count += 1
          raise Phronomy::CancellationError, "cancelled"
        end
      end

      expect {
        retry_agent.new.invoke("x")
      }.to raise_error(Phronomy::CancellationError)
      expect(call_count).to eq(1)
    end
  end

  describe "Agent::Orchestrator#dispatch_parallel integration" do
    let(:orchestrator_class) { Class.new(Phronomy::Agent::Orchestrator) }
    subject(:orchestrator) { orchestrator_class.new }

    # Agent that records the cancellation token it received in its config.
    def token_capturing_agent
      received_tokens = []
      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, messages: []|
          received_tokens << config[:cancellation_token]
          {output: "ok", messages: []}
        end
      end
      [agent_class, received_tokens]
    end

    it "propagates cancellation_token: to each worker task via config" do
      agent_class, received_tokens = token_capturing_agent
      token = described_class.new

      orchestrator.dispatch_parallel(
        {agent: agent_class, input: "t1"},
        {agent: agent_class, input: "t2"},
        cancellation_token: token
      )

      expect(received_tokens).to all(be token)
    end

    it "does not override a token already set in the task config" do
      task_token = described_class.new
      shared_token = described_class.new
      received_tokens = []

      agent_class = Class.new(Phronomy::Agent::Base) do
        define_method(:_invoke_impl) do |_input, config: {}, thread_id: nil, messages: []|
          received_tokens << config[:cancellation_token]
          {output: "ok", messages: []}
        end
      end

      orchestrator.dispatch_parallel(
        {agent: agent_class, input: "t1", config: {cancellation_token: task_token}},
        cancellation_token: shared_token
      )

      expect(received_tokens.first).to be task_token
    end

    it "raises CancellationError when the shared token is pre-cancelled" do
      token = described_class.new
      token.cancel!

      # Bare agent (no invoke override): _invoke_impl checks the token
      # and raises CancellationError before any LLM call is attempted.
      bare_agent = Class.new(Phronomy::Agent::Base)

      expect {
        orchestrator.dispatch_parallel(
          {agent: bare_agent, input: "t1"},
          cancellation_token: token
        )
      }.to raise_error(Phronomy::CancellationError)
    end
  end
end
