# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::AsyncEventApi do
  let(:public_api_methods) do
    %i[
      invoke
      invoke_async
      stream
      stream_async
    ]
  end

  let(:internal_execution_methods) do
    %i[
      _start_invocation
      _handle_agent_completion
      _start_approval_resume
      _register_tool_invocation_session
    ]
  end

  it "is the single implementation owner of the Agent execution API" do
    method_names = public_api_methods + internal_execution_methods
    expected_owners = method_names.to_h do |method_name|
      [method_name, described_class]
    end
    actual_owners = method_names.to_h do |method_name|
      [method_name, Phronomy::Agent::Base.instance_method(method_name).owner]
    end

    expect(actual_owners).to eq(expected_owners)
  end

  it "keeps duplicate execution methods out of Agent::Base" do
    base_public_methods =
      Phronomy::Agent::Base.public_instance_methods(false)
    base_private_methods =
      Phronomy::Agent::Base.private_instance_methods(false)

    expect(base_public_methods & public_api_methods).to be_empty
    expect(base_private_methods & internal_execution_methods).to be_empty
  end
end
