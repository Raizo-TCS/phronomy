# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "Mutation configuration consistency" do
  let(:repository_root) { File.expand_path("../..", __dir__) }

  def load_yaml(path)
    YAML.safe_load_file(path, aliases: true)
  end

  def mutant_subjects
    config = load_yaml(File.join(repository_root, ".mutant.yml"))
    config.fetch("matcher").fetch("subjects")
  end

  def nightly_subjects
    workflow = load_yaml(File.join(repository_root, ".github/workflows/nightly-mutation.yml"))

    workflow
      .fetch("jobs")
      .fetch("mutation")
      .fetch("strategy")
      .fetch("matrix")
      .fetch("include")
      .map { |entry| entry.fetch("subject") }
  end

  it "keeps the nightly mutation matrix aligned with .mutant.yml" do
    expect(nightly_subjects).to contain_exactly(*mutant_subjects)
  end
end
