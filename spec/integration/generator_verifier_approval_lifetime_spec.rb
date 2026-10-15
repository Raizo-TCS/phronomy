# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/factors"
require_relative "support/llm_stub"

RSpec.describe "GeneratorVerifier approval and lifetime", :integration do
  def pipeline_for(phase:, on_approval: nil)
    waiting = IntegrationFactors.approval_resume_agent(IntegrationFactors.approval_tool)
    normal = IntegrationFactors.gv_agent_class
    Phronomy::GeneratorVerifier.new(
      draft_agent: (phase == :draft) ? waiting : normal,
      review_agent: (phase == :review) ? waiting : normal,
      draft_prompt_builder: ->(input, _feedback) { input },
      review_prompt_builder: ->(input, _draft, _citations) { input },
      max_iterations: 1, on_approval: on_approval
    )
  end

  def responses_for(phase, approved: true)
    responses = [LLMStub.tool_call_response("approval_required_tool", {query: "request"})]
    if approved
      responses << ((phase == :draft) ? IntegrationFactors.gv_draft_response : IntegrationFactors.gv_review_response)
    end
    responses.unshift(IntegrationFactors.gv_draft_response) if phase == :review
    responses << IntegrationFactors.gv_review_response if phase == :draft && approved
    responses
  end

  %i[draft review].each do |phase|
    it "keeps #{phase} approval pending, resumes it and releases both real Agents" do
      @llm = LLMStub.activate(responses: responses_for(phase))
      queue = Queue.new
      pipeline = pipeline_for(phase: phase, on_approval: queue.method(:<<))
      task = pipeline.invoke_async("request")
      approval = Timeout.timeout(5) { queue.pop }
      expect(approval.phase).to eq(phase)
      expect(task).not_to be_done
      expect(pipeline.approval_requests).to eq([approval])
      expect(approval.to_h[:request][:items].length).to eq(1)
      reply = approval.respond_async(approved: true)
      expect(task.wait_result(timeout: 5)).to be_accepted
      expect(reply.wait_result(timeout: 5)).to be_nil
      expect { approval.respond_async(approved: false).wait_result(timeout: 5) }
        .to raise_error(Phronomy::Error) { |error| expect(error.code).to eq("generation.inactive") }
      expect(pipeline.release!).to be true
      expect(pipeline.release!).to be false
    end

    it "returns #{phase} tool rejection without parsing it as an answer or retrying" do
      @llm = LLMStub.activate(responses: responses_for(phase, approved: false))
      pipeline = pipeline_for(phase: phase, on_approval: ->(approval) { approval.respond_async(approved: false) })
      result = pipeline.invoke_async("request").wait_result(timeout: 5)
      expect(result.termination_reason).to eq("tool_rejected")
      expect(result.interrupted_phase).to eq(phase.to_s)
      expect(result).not_to be_accepted
      expect(result.confidence).to be_nil
      expect(result.review_approved).to be_nil
      expect(result.output.nil?).to eq(phase == :draft)
      expect(@llm.calls.length).to eq((phase == :draft) ? 1 : 2)
      expect(pipeline.release!).to be true
    end
  end

  it "allows an application to obtain approval without a callback and recover from an invalid reply" do
    @llm = LLMStub.activate(responses: responses_for(:draft))
    pipeline = pipeline_for(phase: :draft)
    task = pipeline.invoke_async("request")
    approval = Timeout.timeout(5) do
      loop do
        current = pipeline.approval_requests.first
        break current if current
        sleep 0.005
      end
    end
    expect { approval.respond_async(approved: nil).wait_result }.to raise_error(ArgumentError)
    expect(task).not_to be_done
    approval.respond_async(approved: true)
    expect(task.wait_result(timeout: 5)).to be_accepted
    expect(pipeline.release!).to be true
  end

  it "cancels approval waiting without changing a caller-owned token" do
    @llm = LLMStub.activate(responses: responses_for(:draft))
    queue = Queue.new
    token = Phronomy::Concurrency::CancellationToken.new
    pipeline = pipeline_for(phase: :draft, on_approval: queue.method(:<<))
    task = pipeline.invoke_async("request", config: {cancellation_token: token})
    Timeout.timeout(5) { queue.pop }
    expect(pipeline.cancel_async.wait_result(timeout: 5)).to be true
    expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::CancellationError)
    expect(token).not_to be_cancelled
    expect(pipeline.release!).to be true
  end

  it "preserves a failing approval callback and cancels its suspended Agent" do
    @llm = LLMStub.activate(responses: responses_for(:draft))
    error = RuntimeError.new("UI queue failed")
    pipeline = pipeline_for(phase: :draft, on_approval: ->(_approval) { raise error })
    expect { pipeline.invoke_async("request").wait_result(timeout: 5) }
      .to raise_error { |raised| expect(raised).to equal(error) }
    expect(pipeline.release!).to be true
  end

  it "rejects overlapping use and release without disturbing the pending approval" do
    @llm = LLMStub.activate(responses: responses_for(:draft))
    queue = Queue.new
    pipeline = pipeline_for(phase: :draft, on_approval: queue.method(:<<))
    task = pipeline.invoke_async("request")
    approval = Timeout.timeout(5) { queue.pop }
    expect { pipeline.invoke("overlap") }.to raise_error(Phronomy::Error) { |error| expect(error.code).to eq("generation.busy") }
    expect { pipeline.release! }.to raise_error(Phronomy::Error) { |error| expect(error.code).to eq("generation.busy") }
    approval.respond_async(approved: true)
    expect(task.wait_result(timeout: 5)).to be_accepted
    pipeline.release!
  end
  %i[cancel_first approval_first].each do |order|
    it "settles approval/cancellation race #{order} without competing commits" do
      @llm = LLMStub.activate(responses: responses_for(:draft))
      queue = Queue.new
      pipeline = pipeline_for(phase: :draft, on_approval: queue.method(:<<))
      task = pipeline.invoke_async("request")
      approval = Timeout.timeout(5) { queue.pop }
      operations = if order == :cancel_first
        [pipeline.cancel_async, approval.respond_async(approved: true)]
      else
        [approval.respond_async(approved: true), pipeline.cancel_async]
      end
      outcomes = Phronomy::TaskResult.all_settled([task, *operations]).wait_result(timeout: 5)
      expect(outcomes.first.error).to be_a(Phronomy::CancellationError)
      expect(task.status).to eq(:cancelled)
      expect(pipeline.release!).to be true
    end
  end
end
