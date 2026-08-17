# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RBS gem packaging" do
  it "includes the public signatures in the gem file list" do
    gemspec_path = File.expand_path("../../phronomy.gemspec", __dir__)
    specification = Gem::Specification.load(gemspec_path)

    expect(specification).not_to be_nil
    expect(specification.files).to include(
      "sig/phronomy.rbs",
      "sig/phronomy/runtime.rbs",
      "sig/phronomy/tool.rbs",
      "sig/phronomy/llm_adapter.rbs",
      "sig/phronomy/agent.rbs",
      "sig/phronomy/workflow.rbs",
      "sig/phronomy/persistence.rbs",
      "sig/phronomy/extensions.rbs"
    )
  end
end
