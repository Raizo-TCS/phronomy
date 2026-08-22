# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::MultiAgent::Runner do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "runner-unit-test-agent", version: 1
      model "stub-model"
    end
  end

  it "returns the main-agent result when no Handoff is requested" do
    main = agent_class.new
    runner = described_class.new(main_agent: main)
    allow(main).to receive(:invoke).and_return({output: "direct answer"})

    result = runner.invoke("question")

    expect(result[:output]).to eq("direct answer")
    expect(result[:agent]).to equal(main)
    expect(result).not_to have_key(:handoff_request)
  end

  it "strips internal phronomy keys from the public result" do
    main = agent_class.new
    runner = described_class.new(main_agent: main)
    allow(main).to receive(:invoke).and_return(
      {output: "answer", _phronomy_handoff_manifest: "internal"}
    )

    result = runner.invoke("question")

    expect(result[:output]).to eq("answer")
    expect(result).not_to have_key(:_phronomy_handoff_manifest)
  end

  it "raises HandoffError when MAX_HANDOFFS is exceeded" do
    source = agent_class.new
    target = agent_class.new
    edge = Phronomy::MultiAgent::Handoff.new(
      source_agent: source,
      target_agent: target,
      policy: Phronomy::MultiAgent::HandoffPolicy.define do
        required :current_request
        selectable :history, default: :include
        selectable :knowledge, default: :exclude
        selectable :tool_exchanges, default: :include
      end
    )
    reverse_edge = Phronomy::MultiAgent::Handoff.new(
      source_agent: target,
      target_agent: source,
      policy: Phronomy::MultiAgent::HandoffPolicy.define do
        required :current_request
        selectable :history, default: :include
        selectable :knowledge, default: :exclude
        selectable :tool_exchanges, default: :include
      end
    )

    runner = described_class.new(main_agent: source, handoffs: [edge, reverse_edge])

    fake_source_request = Phronomy::MultiAgent::HandoffRequest.new(
      handoff: edge,
      responsibility: "continue",
      selection_intent: {}
    )
    fake_target_request = Phronomy::MultiAgent::HandoffRequest.new(
      handoff: reverse_edge,
      responsibility: "back",
      selection_intent: {}
    )

    allow(source).to receive(:invoke).and_return(
      {output: nil, handoff_request: fake_source_request, _phronomy_handoff_manifest: nil}
    )
    allow(target).to receive(:invoke).and_return(
      {output: nil, handoff_request: fake_target_request, _phronomy_handoff_manifest: nil}
    )

    # Stub HandoffProjection so no real Context transfer is attempted.
    stub_context = Phronomy::MultiAgent::HandoffContext.new(responsibility: "stub")
    allow_any_instance_of(Phronomy::MultiAgent::HandoffProjection)
      .to receive(:build).and_return(stub_context)

    expect do
      runner.invoke("ping")
    end.to raise_error(Phronomy::HandoffError, /Exceeded maximum Handoffs/)
  end
end
