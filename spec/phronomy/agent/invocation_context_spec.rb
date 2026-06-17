# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::InvocationContext do
  subject(:ctx) do
    described_class.new(
      agent:    double("agent"),
      input:    "hello",
      messages: [],
      config:   { thread_id: "t-1" }
    )
  end

  describe "initial state" do
    it "stores input" do
      expect(ctx.input).to eq("hello")
    end

    it "stores thread_id from config" do
      expect(ctx.thread_id).to eq("t-1")
    end

    it "defaults tool_call_pending to false" do
      expect(ctx.tool_call_pending).to be false
    end

    it "defaults approval_required to false" do
      expect(ctx.approval_required).to be false
    end

    it "defaults input_blocked to false" do
      expect(ctx.input_blocked).to be false
    end

    it "defaults output_blocked to false" do
      expect(ctx.output_blocked).to be false
    end
  end

  describe "guard helpers" do
    it "input_passed? returns true when not blocked" do
      expect(ctx.input_passed?).to be true
    end

    it "input_blocked? returns false initially" do
      expect(ctx.input_blocked?).to be false
    end

    it "input_blocked? returns true after input_blocked = true" do
      ctx.input_blocked = true
      expect(ctx.input_blocked?).to be true
      expect(ctx.input_passed?).to be false
    end

    it "output_passed? returns true when not blocked" do
      expect(ctx.output_passed?).to be true
    end

    it "output_blocked? returns true after output_blocked = true" do
      ctx.output_blocked = true
      expect(ctx.output_blocked?).to be true
      expect(ctx.output_passed?).to be false
    end

    it "tool_call_pending? returns true after tool_call_pending = true" do
      ctx.tool_call_pending = true
      expect(ctx.tool_call_pending?).to be true
    end

    it "approval_required? returns true after approval_required = true" do
      ctx.approval_required = true
      expect(ctx.approval_required?).to be true
    end
  end
end
