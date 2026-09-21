# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Storage dependency and transaction boundary" do
  it "loads and uses storage without loading domain persistence or execution implementations" do
    source = <<~'CODE'
      require "phronomy"
      # Measure this operation separately from the application loader's documented bootstrap.
      loaded_at_entry = $LOADED_FEATURES.dup
      directory = File.expand_path(ARGV.fetch(0))
      backend = Phronomy::Storage::Backends::InMemory.new
      record = Phronomy::Storage::DurableRecord.new(
        record_type: "opaque.storage-test", format_version: "0.1", payload: {"value" => 1}
      )
      backend.transaction do |tx|
        tx.agents.create(agent_id: "opaque", agent_revision: 7, record: record)
        tx.executions.create_active(execution_id: "run", agent_id: "opaque",
          execution_revision: 0, record: record)
        begin
          tx.executions.create_active(execution_id: "other", agent_id: "opaque",
            execution_revision: 0, record: record)
          abort "admission conflict was not detected"
        rescue Phronomy::Storage::ActiveExecutionConflictError
        end
      end
      abort "opaque record changed" unless backend.agents.load("opaque").payload == {"value" => 1}
      prohibited = %w[agent multi_agent persistence engine]
      loaded = ($LOADED_FEATURES - loaded_at_entry).select { |path| path.start_with?(directory + "/") }
      leaks = loaded.select do |path|
        relative = path.delete_prefix(directory + "/")
        prohibited.any? { |name| relative == "#{name}.rb" || relative.start_with?("#{name}/") }
      end
      abort "upper dependency loaded: #{leaks.join(', ')}" unless leaks.empty?
      puts "isolated storage loading, opaque records, and admission: OK"
    CODE
    directory = File.expand_path("../../../lib/phronomy", __dir__)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.dirname(directory), "-e", source, directory)
    expect(status.success?).to be(true), output
    expect(output).to include("isolated storage loading, opaque records, and admission: OK")
  end

  it "rolls back writes when decoding the backend response fails inside a transaction" do
    backend = Phronomy::Storage::Backends::InMemory.new
    # Persist the correct value, then return a corrupt identity. This exercises
    # F0 rollback after a physical write, without an external effect boundary.
    backend.agents.define_singleton_method(:create) do |**arguments|
      stored = super(**arguments)
      Phronomy::Storage::DurableRecord.new(record_type: stored.record_type,
        format_version: stored.format_version, payload: stored.payload.merge("agent_id" => "wrong"))
    end
    persistence = Phronomy::Persistence.new(backend: backend)
    root = Phronomy::Agent::AgentRoot.create(agent_id: "rollback-agent",
      agent_definition_id: "storage-boundary", agent_definition_version: 1)
    content_id = nil
    expect do
      persistence.transaction do |tx|
        content_id = tx.contents.put_text("must roll back")
        tx.agents.create(root)
      end
    end.to raise_error(Phronomy::Storage::SerializationError, /backend returned Agent root/)
    expect { backend.agents.load(root.agent_id) }.to raise_error(Phronomy::Storage::NotFoundError)
    expect(backend.contents.exist?(content_id)).to be(false)
  end
end
