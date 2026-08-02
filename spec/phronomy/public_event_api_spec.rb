# frozen_string_literal: true

require "spec_helper"

RSpec.describe "public event-driven API" do
  it "exposes Workflow#signal" do
    expect(Phronomy::Workflow.public_instance_methods)
      .to include(:signal)
  end

  it "exposes on_event: on both Agent async APIs" do
    invoke_parameters =
      Phronomy::Agent::Base
        .instance_method(:invoke_async)
        .parameters
    stream_parameters =
      Phronomy::Agent::Base
        .instance_method(:stream_async)
        .parameters

    expect(invoke_parameters).to include([:key, :on_event])
    expect(stream_parameters).to include([:key, :on_event])
  end

  it "does not expose an implicit activity DSL" do
    builder_methods =
      Phronomy::Workflow::Builder.public_instance_methods

    expect(builder_methods).not_to include(
      :activity,
      :activity_timeout
    )
  end
end
