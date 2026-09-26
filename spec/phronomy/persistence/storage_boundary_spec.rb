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
      schema = Phronomy::Storage::Resource.new(id: "test.records", kind: :records,
        attributes: {group: :string}, unique: [{name: :one_group, fields: [:group], where: {}}])
      backend = Phronomy::Storage::Backends::InMemory.new(resources: [schema])
      record = Phronomy::Storage::DurableRecord.new(record_type: "opaque.storage-test", format_version: "0.1", payload: {"value" => 1})
      backend.transaction do |tx|
        tx.records(schema).insert(key: "opaque", revision: 7, attributes: {group: "one"}, record: record)
      end
      begin
        backend.view.records(schema).insert(key: "other", revision: 7, attributes: {group: "one"}, record: record)
        abort "unique constraint was not enforced"
      rescue Phronomy::Storage::UniqueConstraintError
      end
      abort "opaque record changed" unless backend.view.records(schema).fetch("opaque").record.payload == {"value" => 1}
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
    backend = Phronomy::Persistence.in_memory.backend
    # Persist the correct value, then return a corrupt identity. This exercises
    # F0 rollback after a physical write, without an external effect boundary.
    backend.define_singleton_method(:insert_record) do |context, resource, **arguments|
      entry = super(context, resource, **arguments)
      record = entry.record
      corrupt = Phronomy::Storage::DurableRecord.new(record_type: record.record_type,
        format_version: record.format_version, payload: record.payload.merge("agent_id" => "wrong"))
      Phronomy::Storage::Entry::Record.new(**entry.to_h.merge(record: corrupt))
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
    end.to raise_error(Phronomy::Persistence::SerializationError, /backend returned another Agent/)
    expect { persistence.agents.load(root.agent_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(persistence.contents.exist?(content_id)).to be(false)
  end
end
