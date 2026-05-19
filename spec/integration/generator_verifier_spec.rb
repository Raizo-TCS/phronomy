# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

# Group 33: GeneratorVerifier
# Pairwise factors: gv_approval_outcome × gv_iteration_limit × gv_raise_policy
# Generated stubs: 4 cases
#
# Infeasible cases: none — all 4 combinations are structurally valid.
#
# LLM required: No (WebMock)
#
# Each test runs a full Phronomy::GeneratorVerifier pipeline with WebMock-stubbed
# HTTP responses, exercising the actual LLM call path through Agent::Base.

RSpec.describe "Group 33: GeneratorVerifier", :integration do
  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  # Returns an array of LLM stub responses for one draft+review cycle.
  # draft_confidence: Float confidence in the draft response.
  # review_approved: Boolean whether the review approves the draft.
  def one_cycle(draft_confidence: 0.9, review_approved: true)
    [
      IntegrationFactors.gv_draft_response(confidence: draft_confidence),
      IntegrationFactors.gv_review_response(approved: review_approved)
    ]
  end

  # ---------------------------------------------------------------------------
  # TC-001: approved / max_iterations=1 / raise_if_untrusted=true
  #
  # When the verifier approves the first draft, the pipeline converges in 1
  # iteration. Even with raise_if_untrusted enabled, no error is raised because
  # the result is trusted.
  # ---------------------------------------------------------------------------
  describe "TC-001: approved / one / raise" do
    before do
      @llm = LLMStub.activate(responses: one_cycle(review_approved: true))
    end

    let(:pipeline) do
      IntegrationFactors.gv_pipeline(
        approval_outcome: :approved,
        iteration_limit: :one,
        raise_policy: :raise
      )
    end

    it "returns a trusted result" do
      result = pipeline.invoke("What is the refund policy?")
      expect(result).to be_trusted
    end

    it "completes in exactly 1 iteration" do
      result = pipeline.invoke("What is the refund policy?")
      expect(result.iterations).to eq(1)
    end

    it "does not raise LowConfidenceError even when raise_if_untrusted is true" do
      expect { pipeline.invoke("What is the refund policy?") }.not_to raise_error
    end

    it "LLM is called exactly twice (1 draft + 1 review)" do
      pipeline.invoke("What is the refund policy?")
      expect(@llm.calls.size).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  # TC-002: approved / max_iterations=3 / raise_if_untrusted=false
  #
  # Approval on the first of three allowed iterations: early exit before the
  # iteration limit is reached.
  # ---------------------------------------------------------------------------
  describe "TC-002: approved / three / no_raise" do
    before do
      # Only 1 cycle needed; extra responses never reached.
      @llm = LLMStub.activate(responses: one_cycle(review_approved: true))
    end

    let(:pipeline) do
      IntegrationFactors.gv_pipeline(
        approval_outcome: :approved,
        iteration_limit: :three,
        raise_policy: :no_raise
      )
    end

    it "returns a trusted result" do
      result = pipeline.invoke("test")
      expect(result).to be_trusted
    end

    it "exits after the first iteration despite max_iterations=3" do
      result = pipeline.invoke("test")
      expect(result.iterations).to eq(1)
    end

    it "includes citations parsed from the draft response" do
      result = pipeline.invoke("test")
      expect(result.citations).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-003: rejected / max_iterations=1 / raise_if_untrusted=false
  #
  # Verifier rejects the only allowed draft. Result is untrusted; no error raised.
  # ---------------------------------------------------------------------------
  describe "TC-003: rejected / one / no_raise" do
    before do
      @llm = LLMStub.activate(responses: one_cycle(review_approved: false))
    end

    let(:pipeline) do
      IntegrationFactors.gv_pipeline(
        approval_outcome: :rejected,
        iteration_limit: :one,
        raise_policy: :no_raise
      )
    end

    it "returns an untrusted result" do
      result = pipeline.invoke("test")
      expect(result).not_to be_trusted
    end

    it "stops after 1 iteration" do
      result = pipeline.invoke("test")
      expect(result.iterations).to eq(1)
    end

    it "does not raise even though the result is untrusted" do
      expect { pipeline.invoke("test") }.not_to raise_error
    end

    it "accumulates reviewer feedback in review_notes" do
      result = pipeline.invoke("test")
      expect(result.review_notes).not_to be_empty
      expect(result.review_notes.first).to include("Missing citation")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-004: rejected / max_iterations=3 / raise_if_untrusted=true
  #
  # Pattern 1 core requirement: feedback is routed back to the generator on each
  # rejected cycle. After exhausting max_iterations=3, LowConfidenceError is
  # raised and carries the Result with accumulated review_notes.
  #
  # This test verifies the feedback loop at the LLM call layer:
  # the draft agent's second and third prompts contain the rejection feedback.
  # ---------------------------------------------------------------------------
  describe "TC-004: rejected / three / raise — Pattern 1 core requirement" do
    before do
      # 3 rejected cycles: draft + review × 3.
      @llm = LLMStub.activate(
        responses: [
          *one_cycle(draft_confidence: 0.3, review_approved: false),
          *one_cycle(draft_confidence: 0.3, review_approved: false),
          *one_cycle(draft_confidence: 0.3, review_approved: false)
        ]
      )
    end

    let(:pipeline) do
      IntegrationFactors.gv_pipeline(
        approval_outcome: :rejected,
        iteration_limit: :three,
        raise_policy: :raise
      )
    end

    it "raises LowConfidenceError after exhausting max_iterations" do
      expect { pipeline.invoke("test") }.to raise_error(Phronomy::LowConfidenceError)
    end

    it "attaches the Result to the error with review_notes from all cycles" do
      pipeline.invoke("test")
    rescue Phronomy::LowConfidenceError => e
      expect(e.result.iterations).to eq(3)
      expect(e.result.review_notes.size).to eq(3)
      expect(e.result.review_notes).to all(include("Missing citation"))
    end

    it "makes 6 LLM calls (3 drafts + 3 reviews)" do
      pipeline.invoke("test")
    rescue Phronomy::LowConfidenceError
      expect(@llm.calls.size).to eq(6)
    end

    # Verify the core Pattern 1 requirement: the draft prompt on iteration 2+
    # contains the reviewer's feedback from the previous cycle.
    it "draft prompt on iteration 2 contains reviewer feedback from iteration 1" do
      pipeline.invoke("test")
    rescue Phronomy::LowConfidenceError
      # LLM call index 2 is the second draft agent call.
      second_draft_user_msg = @llm.messages_for(2).find { |m| m["role"] == "user" }
      expect(second_draft_user_msg["content"]).to include("Missing citation")
    end
  end

  # ---------------------------------------------------------------------------
  # Pattern 1 requirement: feedback routing
  #
  # The Anthropic blog describes Pattern 1 as: "If rejected, that feedback is
  # routed back to the generator, which uses it to produce a revised attempt."
  # This describe block verifies this property directly at the LLM prompt level.
  # ---------------------------------------------------------------------------
  describe "Pattern 1 requirement: verifier feedback routed to generator" do
    before do
      # 2 cycles: first rejected (feedback generated), second approved.
      @llm = LLMStub.activate(
        responses: [
          *one_cycle(draft_confidence: 0.3, review_approved: false),
          *one_cycle(review_approved: true)
        ]
      )
    end

    let(:pipeline) do
      IntegrationFactors.gv_pipeline(
        approval_outcome: :approved,
        iteration_limit: :three,
        raise_policy: :no_raise
      )
    end

    it "the second draft prompt contains the reviewer's rejection feedback" do
      pipeline.invoke("What is the warranty period?")
      # LLM call 0: draft 1; call 1: review 1 (rejected); call 2: draft 2
      second_draft_user_msg = @llm.messages_for(2).find { |m| m["role"] == "user" }
      expect(second_draft_user_msg["content"]).to include("Missing citation")
    end

    it "converges on the second attempt (2 iterations total)" do
      result = pipeline.invoke("What is the warranty period?")
      expect(result.iterations).to eq(2)
    end

    it "the final result is trusted" do
      result = pipeline.invoke("What is the warranty period?")
      expect(result).to be_trusted
    end
  end
end
