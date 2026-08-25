# frozen_string_literal: true

require "spec_helper"

RSpec.describe "public event-driven API" do
  it "exposes Workflow#signal" do
    expect(Phronomy::Workflow.public_instance_methods)
      .to include(:signal)
  end

  it "binds Agent events at live materialization rather than async invocation" do
    create_parameters =
      Phronomy::Agent::Base
        .method(:create)
        .parameters
    load_parameters =
      Phronomy::Agent::Base
        .method(:load)
        .parameters
    invoke_parameters =
      Phronomy::Agent::Base
        .instance_method(:invoke_async)
        .parameters
    stream_parameters =
      Phronomy::Agent::Base
        .instance_method(:stream_async)
        .parameters

    expect(create_parameters).to include([:key, :on_event])
    expect(load_parameters).to include([:key, :on_event])
    expect(invoke_parameters).not_to include([:key, :on_event])
    expect(stream_parameters).not_to include([:key, :on_event])
  end

  it "exposes Recovery resolution on Agent" do
    expect(Phronomy::Agent::Base.public_instance_methods)
      .to include(:resolve, :resolve_async)
  end

  it "does not expose a generic Recovery resume API" do
    expect(Phronomy::Agent::Base.public_instance_methods)
      .not_to include(:recover, :recover_async, :resume_async)
  end

  it "exposes action: on Workflow transition definitions" do
    transition_parameters =
      Phronomy::Workflow::Builder
        .instance_method(:transition)
        .parameters

    expect(transition_parameters).to include([:key, :action])
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
