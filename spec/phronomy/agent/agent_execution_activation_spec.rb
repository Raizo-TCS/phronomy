# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AgentExecutionActivation do
  it "binds each Runtime LLM result to the active Manifest and start time" do
    projection = Struct.new(:manifest_ref, :manifest).new("sha256:base", Object.new)
    execution = Struct.new(:execution_id).new("execution-1")
    activation = described_class.new(
      execution: execution,
      agent: Object.new,
      runtime_projection: projection,
      coordinator: Object.new
    )

    call_projection = Struct.new(:manifest_ref).new("sha256:call-1")
    activation.begin_llm_call(call_projection)
    activation.record_llm_result(response: Object.new, error: nil, streaming: false)

    item = activation.runtime_snapshot.fetch(:llm_results).fetch(0)
    expect(item.fetch(:manifest_ref)).to eq("sha256:call-1")
    expect(item.fetch(:started_at)).to be_a(String)
  end
end
