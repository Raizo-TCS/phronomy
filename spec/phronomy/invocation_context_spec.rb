# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::InvocationContext do
  subject(:ctx) { described_class.new }

  describe "defaults" do
    it "has nil thread_id by default" do
      expect(ctx.thread_id).to be_nil
    end

    it "defaults max_parallel_tools to 10" do
      expect(ctx.max_parallel_tools).to eq(10)
    end

    it "has nil cancellation_token by default" do
      expect(ctx.cancellation_token).to be_nil
    end
  end

  describe "#merge" do
    it "returns a new InvocationContext" do
      merged = ctx.merge(thread_id: "abc")
      expect(merged).to be_a(described_class)
      expect(merged).not_to be(ctx)
    end

    it "overrides specified attributes" do
      merged = ctx.merge(thread_id: "t1", max_parallel_tools: 3)
      expect(merged.thread_id).to eq("t1")
      expect(merged.max_parallel_tools).to eq(3)
    end

    it "keeps unspecified attributes" do
      base = described_class.new(thread_id: "original", user_id: "u1")
      merged = base.merge(thread_id: "new")
      expect(merged.user_id).to eq("u1")
    end
  end

  describe "#effective_cancellation_token" do
    it "returns the assigned token when present" do
      token = Phronomy::CancellationToken.new
      ctx = described_class.new(cancellation_token: token)
      expect(ctx.effective_cancellation_token).to be(token)
    end

    it "returns a fresh token when none was assigned" do
      expect(ctx.effective_cancellation_token).to be_a(Phronomy::CancellationToken)
    end
  end

  describe "#effective_timeout_token" do
    it "returns nil when neither cancellation_token nor deadline is set" do
      expect(ctx.effective_timeout_token).to be_nil
    end

    it "returns the explicit cancellation_token when set" do
      token = Phronomy::CancellationToken.new
      ic = described_class.new(cancellation_token: token)
      expect(ic.effective_timeout_token).to be(token)
    end

    it "returns a new token and attaches the deadline when only deadline is set" do
      ic = described_class.new(deadline: Phronomy::Deadline.in(30))
      tok = ic.effective_timeout_token
      expect(tok).to be_a(Phronomy::CancellationToken)
      expect(tok).not_to be_nil
    end

    it "cancels the token when an expired deadline is attached" do
      # A deadline already in the past has remaining_seconds of 0, so attach_to
      # is a no-op. Use a very short future deadline instead.
      ic = described_class.new(deadline: Phronomy::Deadline.in(0.02))
      tok = ic.effective_timeout_token
      # Token should be cancelled once the deadline fires
      sleep 0.15
      expect(tok.cancelled?).to be true
    end
  end

  describe "keyword arguments" do
    it "accepts all documented attributes" do
      token = Phronomy::CancellationToken.new
      ctx = described_class.new(
        thread_id: "t1",
        session_id: "s1",
        user_id: "u1",
        cancellation_token: token,
        deadline: Phronomy::Deadline.in(30),
        token_budget: 4096,
        max_parallel_tools: 5,
        provider_limits: {openai: {rpm: 60}}
      )
      expect(ctx.thread_id).to eq("t1")
      expect(ctx.session_id).to eq("s1")
      expect(ctx.user_id).to eq("u1")
      expect(ctx.cancellation_token).to be(token)
      expect(ctx.token_budget).to eq(4096)
      expect(ctx.max_parallel_tools).to eq(5)
      expect(ctx.provider_limits).to eq({openai: {rpm: 60}})
    end
  end
end
