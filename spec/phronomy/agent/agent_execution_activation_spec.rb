# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentExecutionActivation do
  it "allocates Provider Call identity before settlement and preserves it in the Runtime result" do
    projection = Struct.new(:manifest_ref, :manifest).new("sha256:base", Object.new)
    execution = Struct.new(:execution_id).new("execution-1")
    activation = described_class.new(
      execution: execution,
      agent: Object.new,
      runtime_projection: projection,
      coordinator: Object.new
    )

    call_projection = Struct.new(:manifest_ref).new("sha256:call-1")
    call_context = activation.begin_llm_call(call_projection)
    expect(call_context.fetch(:llm_call_id)).to match(/\A[0-9a-f-]{36}\z/)

    activation.record_llm_result(response: Object.new, error: nil, streaming: false)

    item = activation.runtime_snapshot.fetch(:llm_results).fetch(0)
    expect(item.fetch(:llm_call_id)).to eq(call_context.fetch(:llm_call_id))
    expect(item.fetch(:manifest_ref)).to eq("sha256:call-1")
    expect(item.fetch(:started_at)).to be_a(String)
  end

  it "rejects a settled LLM result that has no active Provider Call" do
    projection = Struct.new(:manifest_ref, :manifest).new("sha256:base", Object.new)
    execution = Struct.new(:execution_id).new("execution-1")
    activation = described_class.new(
      execution: execution,
      agent: Object.new,
      runtime_projection: projection,
      coordinator: Object.new
    )

    expect {
      activation.record_llm_result(response: Object.new, error: nil, streaming: false)
    }.to raise_error(Phronomy::Error, /without an active Provider Call/)
  end
  it "rejects overlapping Provider Calls before provenance can be overwritten" do
    projection = Struct.new(:manifest_ref, :manifest).new("sha256:base", Object.new)
    execution = Struct.new(:execution_id).new("execution-1")
    activation = described_class.new(
      execution: execution,
      agent: Object.new,
      runtime_projection: projection,
      coordinator: Object.new
    )

    activation.begin_llm_call(Struct.new(:manifest_ref).new("sha256:call-1"))

    expect {
      activation.begin_llm_call(Struct.new(:manifest_ref).new("sha256:call-2"))
    }.to raise_error(Phronomy::Error, /another Provider Call is active/)
  end
end
