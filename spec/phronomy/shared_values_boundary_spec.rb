# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Shared value dependency boundary" do
  it "builds recovery facts and Team records without loading Agent or execution code" do
    source = <<~'CODE'
      require "phronomy"

      facts = {"observed" => ["before"]}
      classification = Phronomy::Recovery::Classification.new(
        disposition: :resumable, reason: :checkpoint, facts: facts
      )
      facts.fetch("observed") << "after"
      abort "recovery facts retained mutable input" unless classification.facts == {"observed" => ["before"]}
      abort "recovery facts are mutable" unless classification.facts.fetch("observed").frozen?

      timestamp = "2026-09-17T00:00:00Z"
      root = Phronomy::MultiAgent::TeamRoot.new(
        team_id: "team", team_definition_id: "definition", team_definition_version: 1,
        team_revision: 0, lifecycle_status: "idle", created_at: timestamp,
        updated_at: timestamp, metadata: {"labels" => ["retained"]}
      )
      execution = Phronomy::MultiAgent::TeamExecution.new(
        team_execution_id: "run", team_id: root.team_id, execution_revision: 0,
        status: "active", phase: "preparing", input_ref: nil, coordinator: {},
        tasks: [], workers: [], assignments: [], result_ref: nil, error_ref: nil,
        created_at: timestamp, updated_at: timestamp, metadata: {}
      )
      abort "Team value containers are mutable" unless root.metadata.fetch("labels").frozen? && execution.tasks.frozen?
      Phronomy::Values::Immutable.validate_canonical_json!(root.to_h, label: "Team root")

      directory = File.expand_path(ARGV.fetch(0))
      prohibited = %w[agent engine persistence workflow]
      leaks = $LOADED_FEATURES.select do |path|
        next false unless path.start_with?(directory + "/")
        relative = path.delete_prefix(directory + "/")
        prohibited.any? { |name| relative == "#{name}.rb" || relative.start_with?("#{name}/") }
      end
      abort "upper implementation loaded: #{leaks.join(', ')}" unless leaks.empty?
      puts "shared recovery and Team values without Agent or execution loading: OK"
    CODE
    directory = File.expand_path("../../lib/phronomy", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.dirname(directory), "-e", source, directory)
    expect(status.success?).to be(true), output
    expect(output).to include("shared recovery and Team values without Agent or execution loading: OK")
  end
end
