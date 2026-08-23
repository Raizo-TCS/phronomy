# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::InvocationContext do
  subject(:ctx) { described_class.new }

  describe "generic identity removal" do
    it "does not expose thread_id or session_id" do
      expect(ctx).not_to respond_to(:thread_id)
      expect(ctx).not_to respond_to(:session_id)
    end

    it "rejects removed generic identity keywords" do
      expect {
        described_class.new(thread_id: "legacy")
      }.to raise_error(ArgumentError, /thread_id/)

      expect {
        described_class.new(session_id: "legacy")
      }.to raise_error(ArgumentError, /session_id/)
    end

    it "does not introduce a replacement generic correlation field" do
      expect(ctx).not_to respond_to(:correlation_id)
      expect(ctx).not_to respond_to(:conversation_id)
      expect(ctx).not_to respond_to(:application_session_id)
    end
  end

  describe "#merge" do
    it "returns a new InvocationContext" do
      merged = ctx.merge(user_id: "u1")
      expect(merged).to be_a(described_class)
      expect(merged).not_to be(ctx)
    end

    it "overrides specified attributes" do
      policy = ->(_request) { :allow }
      merged = ctx.merge(user_id: "u1", approval_policy: policy)
      expect(merged.user_id).to eq("u1")
      expect(merged.approval_policy).to be(policy)
    end

    it "keeps unspecified attributes" do
      base = described_class.new(user_id: "original", task_id: "task-1")
      merged = base.merge(user_id: "new")
      expect(merged.task_id).to eq("task-1")
    end
  end

  describe "#effective_cancellation_token" do
    it "returns the assigned token when present" do
      token = Phronomy::Concurrency::CancellationToken.new
      ctx = described_class.new(cancellation_token: token)
      expect(ctx.effective_cancellation_token).to be(token)
    end

    it "returns a fresh token when none was assigned" do
      expect(ctx.effective_cancellation_token)
        .to be_a(Phronomy::Concurrency::CancellationToken)
    end
  end

  describe "#effective_timeout_token" do
    it "returns nil when neither cancellation_token nor deadline is set" do
      expect(ctx.effective_timeout_token).to be_nil
    end

    it "returns the explicit cancellation_token when set" do
      token = Phronomy::Concurrency::CancellationToken.new
      ic = described_class.new(cancellation_token: token)
      expect(ic.effective_timeout_token).to be(token)
    end

    it "returns a new token and attaches the deadline when only deadline is set" do
      ic = described_class.new(
        deadline: Phronomy::Concurrency::Deadline.in(30)
      )
      tok = ic.effective_timeout_token
      expect(tok).to be_a(Phronomy::Concurrency::CancellationToken)
      expect(tok).not_to be_nil
    end

    it "cancels the token when an attached deadline expires" do
      ic = described_class.new(
        deadline: Phronomy::Concurrency::Deadline.in(0.02)
      )
      tok = ic.effective_timeout_token
      sleep 0.15
      expect(tok.cancelled?).to be true
    end
  end

  describe "keyword arguments" do
    it "accepts remaining purpose-specific control and tracing attributes" do
      token = Phronomy::Concurrency::CancellationToken.new
      policy = ->(_request) { :allow }
      redaction = Object.new
      ctx = described_class.new(
        user_id: "u1",
        cancellation_token: token,
        deadline: Phronomy::Concurrency::Deadline.in(30),
        token_budget: 4096,
        approval_policy: policy,
        redaction_policy: redaction,
        task_id: "task-1",
        parent_task_id: "task-0"
      )
      expect(ctx.user_id).to eq("u1")
      expect(ctx.cancellation_token).to be(token)
      expect(ctx.token_budget).to eq(4096)
      expect(ctx.approval_policy).to be(policy)
      expect(ctx.redaction_policy).to be(redaction)
      expect(ctx.task_id).to eq("task-1")
      expect(ctx.parent_task_id).to eq("task-0")
    end
  end
end
