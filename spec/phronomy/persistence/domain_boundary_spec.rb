# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Domain persistence ownership boundary" do
  it "round-trips Team records without loading additional Agent, Workflow, or composition code" do
    source = <<~'CODE'
      require "phronomy"
      # Measure this operation separately from the application loader's documented bootstrap.
      loaded_at_entry = $LOADED_FEATURES.dup
      timestamp = "2026-09-18T00:00:00Z"
      root = Phronomy::MultiAgent::TeamRoot.new(
        team_id: "team", team_definition_id: "definition", team_definition_version: 1,
        team_revision: 0, lifecycle_status: "idle", created_at: timestamp,
        updated_at: timestamp, metadata: {}
      )
      execution = Phronomy::MultiAgent::TeamExecution.new(
        team_execution_id: "run", team_id: root.team_id, execution_revision: 0,
        status: "active", phase: "preparing", input_ref: nil, coordinator: {},
        tasks: [], workers: [], assignments: [], result_ref: nil, error_ref: nil,
        created_at: timestamp, updated_at: timestamp, metadata: {}
      )
      schema = Phronomy::TeamStorageSchema
      backend = Phronomy::Storage::Backends::InMemory.new(resources: [schema::ROOTS, schema::EXECUTIONS])
      roots = Phronomy::MultiAgent::Persistence::TeamRepository.new(backend.view)
      runs = Phronomy::MultiAgent::Persistence::TeamExecutionRepository.new(backend.view)
      backend.transaction do
        roots.create(root)
        runs.create_active(execution)
      end
      abort "Team root changed" unless roots.load(root.team_id).to_h == root.to_h
      abort "Team execution changed" unless runs.load(execution.team_execution_id).to_h == execution.to_h
      directory = File.expand_path(ARGV.fetch(0))
      prohibited = %w[agent workflow persistence persistence_composition engine]
      leaks = ($LOADED_FEATURES - loaded_at_entry).select do |path|
        next false unless path.start_with?(directory + "/")
        relative = path.delete_prefix(directory + "/")
        prohibited.any? { |name| relative == "#{name}.rb" || relative.start_with?("#{name}/") }
      end
      abort "unrelated implementation loaded: #{leaks.join(', ')}" unless leaks.empty?
      puts "independent Team persistence: OK"
    CODE
    directory = File.expand_path("../../../lib/phronomy", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.dirname(directory), "-e", source, directory)
    expect(status.success?).to be(true), output
    expect(output).to include("independent Team persistence: OK")
  end

  it "uses the public Agent repositories without loading additional Team or Workflow implementations" do
    source = <<~'CODE'
      require "phronomy"
      # Measure this operation separately from the application loader's documented bootstrap.
      loaded_at_entry = $LOADED_FEATURES.dup
      persistence = Phronomy::Persistence.in_memory
      root = Phronomy::Agent::AgentRoot.create(agent_id: "isolated-agent",
        agent_definition_id: "boundary", agent_definition_version: 1)
      persistence.transaction { |tx| tx.agents.create(root) }
      abort "Agent root changed" unless persistence.agents.load(root.agent_id).to_h == root.to_h
      abort "repository identity changed" unless persistence.agents.equal?(persistence.agents)
      directory = File.expand_path(ARGV.fetch(0))
      leaks = ($LOADED_FEATURES - loaded_at_entry).select do |path|
        next false unless path.start_with?(directory + "/")
        relative = path.delete_prefix(directory + "/")
        next false if relative.end_with?("storage_schema.rb") || relative.include?("storage_contract/")
        %w[multi_agent workflow].any? { |name| relative == "#{name}.rb" || relative.start_with?("#{name}/") }
      end
      abort "unrelated implementation loaded: #{leaks.join(', ')}" unless leaks.empty?
      puts "independent public Agent persistence: OK"
    CODE
    directory = File.expand_path("../../../lib/phronomy", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.dirname(directory), "-e", source, directory)
    expect(status.success?).to be(true), output
    expect(output).to include("independent public Agent persistence: OK")
  end

  it "rolls back Agent, Team, and content writes when the Team response fails validation" do
    backend = Phronomy::Persistence.in_memory.backend
    # F0 after physical writes, within one backend transaction; no X0 effect.
    backend.define_singleton_method(:insert_record) do |context, resource, **arguments|
      entry = super(context, resource, **arguments)
      next entry unless resource.id == "team.roots"
      record = entry.record
      corrupt = Phronomy::Storage::DurableRecord.new(record_type: record.record_type,
        format_version: record.format_version, payload: record.payload.merge("team_id" => "wrong-team"))
      Phronomy::Storage::Entry::Record.new(**entry.to_h.merge(record: corrupt))
    end
    persistence = Phronomy::Persistence.new(backend: backend)
    agent = Phronomy::Agent::AgentRoot.create(agent_id: "rollback-agent",
      agent_definition_id: "domain-boundary", agent_definition_version: 1)
    timestamp = "2026-09-18T00:00:00Z"
    team = Phronomy::MultiAgent::TeamRoot.new(
      team_id: "rollback-team", team_definition_id: "domain-boundary", team_definition_version: 1,
      team_revision: 0, lifecycle_status: "idle", created_at: timestamp, updated_at: timestamp, metadata: {}
    )
    content_id = nil

    expect do
      persistence.transaction do |tx|
        content_id = tx.contents.put_text("shared transaction")
        tx.agents.create(agent)
        tx.teams.create(team)
      end
    end.to raise_error(Phronomy::Storage::SerializationError, /backend returned another Team/)

    expect { persistence.agents.load(agent.agent_id) }.to raise_error(Phronomy::Storage::NotFoundError)
    expect { persistence.teams.load(team.team_id) }.to raise_error(Phronomy::Storage::NotFoundError)
    expect(persistence.contents.exist?(content_id)).to be(false)
  end
end
