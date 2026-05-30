# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::CancellationToken do
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

    it "accepts a monotonic_deadline option and is cancelled once it has elapsed" do
      token = described_class.new(
        monotonic_deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      )
      expect(token.cancelled?).to be true
    end

    it "initialises the callback list so on_cancel can be called on a fresh token" do
      token = described_class.new
      received = []
      token.on_cancel { received << :called }
      token.cancel!
      expect(received).to eq([:called])
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
      result = token.cancel!
      expect(result).to be token
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

    it "returns true when the wall-clock deadline is exactly equal to the current time" do
      t = Time.now
      token = described_class.new(deadline: t)
      allow(Time).to receive(:now).and_return(t)
      expect(token.cancelled?).to be true
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

    it "uses Process.clock_gettime to establish the monotonic deadline" do
      fixed_now = 100_000.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(fixed_now)
      token = described_class.timeout_after(30)
      expect(token.remaining_monotonic_seconds).to be_within(0.001).of(30.0)
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
    let(:orchestrator_class) { Class.new(Phronomy::MultiAgent::Orchestrator) }
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

  describe "#on_cancel" do
    it "calls the block when cancel! is subsequently called" do
      token = described_class.new
      called = false
      token.on_cancel { called = true }
      expect(called).to be false
      token.cancel!
      expect(called).to be true
    end

    it "calls the block immediately when the token is already cancelled" do
      token = described_class.new
      token.cancel!
      called = false
      token.on_cancel { called = true }
      expect(called).to be true
    end

    it "calls all registered callbacks in order when cancel! fires" do
      token = described_class.new
      order = []
      token.on_cancel { order << :first }
      token.on_cancel { order << :second }
      token.on_cancel { order << :third }
      token.cancel!
      expect(order).to eq([:first, :second, :third])
    end

    it "does NOT call callbacks for deadline-based expiry (monotonic clock)" do
      token = described_class.timeout_after(3600)
      called = false
      token.on_cancel { called = true }
      # Simulate deadline expiry without explicit cancel!: cancelled? returns true
      # but on_cancel callbacks must NOT fire.
      expect(token.cancelled?).to be false
      expect(called).to be false
    end

    it "returns self to allow chaining" do
      token = described_class.new
      expect(token.on_cancel {}).to be token
    end

    it "does not fire the same callback more than once when cancel! is called twice" do
      token = described_class.new
      call_count = 0
      token.on_cancel { call_count += 1 }
      token.cancel!
      token.cancel!
      expect(call_count).to eq(1)
    end
  end

  describe "#remaining_monotonic_seconds" do
    it "returns nil when no monotonic deadline is set" do
      token = described_class.new
      expect(token.remaining_monotonic_seconds).to be_nil
    end

    it "returns nil when only a wall-clock deadline is set" do
      token = described_class.new(deadline: Time.now + 60)
      expect(token.remaining_monotonic_seconds).to be_nil
    end

    it "returns a positive Float when the deadline is in the future" do
      token = described_class.timeout_after(30)
      remaining = token.remaining_monotonic_seconds
      expect(remaining).to be_a(Float)
      expect(remaining).to be > 0.0
      expect(remaining).to be <= 30.0
    end

    it "returns 0.0 (not negative) when the deadline has already passed" do
      token = described_class.timeout_after(-1)
      expect(token.remaining_monotonic_seconds).to eq(0.0)
    end

    it "decreases over time" do
      token = described_class.timeout_after(10)
      first = token.remaining_monotonic_seconds
      sleep 0.05
      second = token.remaining_monotonic_seconds
      expect(second).to be < first
    end
  end

  describe "#cancel! callback invocation" do
    it "fires all on_cancel callbacks exactly once even if cancel! is called concurrently" do
      token = described_class.new
      counter = Mutex.new
      count = 0
      10.times { token.on_cancel { counter.synchronize { count += 1 } } }
      threads = 5.times.map { Thread.new { token.cancel! } }
      threads.each(&:join)
      expect(count).to eq(10)
    end
  end

  describe "#cancelled? monotonic deadline" do
    it "returns false when the monotonic deadline has not elapsed" do
      token = described_class.timeout_after(3600)
      expect(token.cancelled?).to be false
    end

    it "returns true when the monotonic deadline has elapsed" do
      token = described_class.timeout_after(-1)
      expect(token.cancelled?).to be true
    end

    it "returns true once cancel! is called regardless of the monotonic deadline" do
      token = described_class.timeout_after(3600)
      token.cancel!
      expect(token.cancelled?).to be true
    end

    it "returns true when the monotonic clock is exactly at the deadline (>= boundary)" do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      token = described_class.new(monotonic_deadline: now)
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(now)
      expect(token.cancelled?).to be true
    end
  end
end
