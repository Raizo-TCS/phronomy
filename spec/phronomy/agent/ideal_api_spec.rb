# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ideal stateful Agent API" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "ideal-test-agent", version: 1
    end
  end

  it "does not expose invoke(messages:), owns_context, or a stateful mode switch" do
    parameters = Phronomy::Agent::AsyncEventApi.instance_method(:invoke).parameters
    expect(parameters.none? { |_kind, name| name == :messages }).to be(true)
    expect(agent_class).not_to respond_to(:owns_context)
  end

  it "always has a Persistence backend" do
    agent = agent_class.create
    expect(agent.persistence).to be_a(Phronomy::Persistence::InMemory)
  end

  it "allows Agent.run_once to register creation-time Knowledge" do
    observed_knowledge = []
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "ideal-run-once-knowledge-test", version: 1

      define_method(:invoke) do |_input, **_options|
        observed_knowledge.concat(
          journal_projection.context_records
            .select { |record| record.kind == :knowledge }
            .map { |record| persistence.contents.fetch_text(record.content_ref) }
        )
        {output: "ok", messages: []}
      end
    end

    result = Phronomy::Agent.run_once(
      definition: klass,
      input: "hello",
      knowledge: ["Policy: be concise."]
    )

    expect(result[:output]).to eq("ok")
    expect(observed_knowledge).to eq(["Policy: be concise."])
  end
end
