# frozen_string_literal: true

require "spec_helper"

RSpec.describe "SharedState member model configuration" do
  def member_agent(id:, model_name: nil)
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: id, version: 1
      model model_name if model_name
      provider :openai
      instructions "Return a brief finding."
    end
  end

  # Exercise normal SharedState and Agent execution without a live provider.
  def capture_requests(members:, global_model: nil)
    requests = []
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        requests << request
        Phronomy::LLMAdapter::Response.new(content: "done", finish_reason: :stop)
      end
      protected :perform_complete
    end.new
    team = Class.new(Phronomy::MultiAgent::SharedState) { max_cycles 1 }
    members.each { |member| team.member(member) }

    Phronomy.with_configuration do |configuration|
      configuration.llm_adapter = adapter
      configuration.default_model = global_model
      team.new.invoke("Review this task without network access.")
    end
    requests
  end

  it "preserves an explicit member model when the global model is nil" do
    member = member_agent(id: "shared-state-explicit-model", model_name: "openai/gpt-oss-20b")
    requests = capture_requests(members: [member])

    expect(requests.map { |request| request.model_config["model"] }).to eq(["openai/gpt-oss-20b"])
    expect(member.model).to eq("openai/gpt-oss-20b")
  end

  it "preserves different member models instead of substituting the global model" do
    members = [
      member_agent(id: "shared-state-first-model", model_name: "first-member-model"),
      member_agent(id: "shared-state-second-model", model_name: "second-member-model")
    ]
    requests = capture_requests(members: members, global_model: "global-fallback")

    expect(requests.map { |request| request.model_config["model"] })
      .to eq(["first-member-model", "second-member-model"])
    expect(members.map(&:model)).to eq(["first-member-model", "second-member-model"])
  end

  it "uses the global default when the member has no explicit model" do
    member = member_agent(id: "shared-state-global-model")
    requests = capture_requests(members: [member], global_model: "global-fallback")

    expect(requests.map { |request| request.model_config["model"] }).to eq(["global-fallback"])
  end

  it "retains the member provider and both coordination tools" do
    member = member_agent(id: "shared-state-provider-tools", model_name: "openai/gpt-oss-20b")
    requests = capture_requests(members: [member])

    expect(requests.fetch(0).model_config["provider"]).to eq("openai")
    expect(requests.fetch(0).tools.map { |tool| tool.fetch("name") })
      .to include("read_store", "write_finding")
  end
end
