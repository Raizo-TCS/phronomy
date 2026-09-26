# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Storage::Resource do
  let(:record) { Phronomy::Storage::DurableRecord.new(record_type: "opaque", format_version: "0.1", payload: {}) }

  it "supports independent declared resources, typed nullable attributes and named indexes" do
    resource = described_class.new(id: "inventory.items", kind: :records,
      attributes: {code: :nullable_string, visible: :boolean, quantity: :integer},
      indexes: {by_code: [:code]}, unique: [{name: :code, fields: [:code], where: {}}])
    backend = Phronomy::Storage::Backends::InMemory.new(resources: [resource])
    handle = backend.view.records(resource)
    %w[first second].each do |key|
      handle.insert(key: key, revision: 4, attributes: {code: nil, visible: false, quantity: 0}, record: record)
    end
    expect(handle.scan(index: :by_code, equals: {code: nil}).map(&:key)).to eq(%w[first second])
    handle.insert(key: "third", revision: 4, attributes: {code: "fixed", visible: true, quantity: 2}, record: record)
    expect { handle.insert(key: "fourth", revision: 4, attributes: {code: "fixed", visible: true, quantity: 3}, record: record) }
      .to raise_error(Phronomy::Storage::UniqueConstraintError)
  end

  it "freezes declarations independently of caller-owned input" do
    id = +"example"
    fields = [:label]
    attributes = {label: :string}
    resource = described_class.new(id: id, kind: :records, attributes: attributes, indexes: {label: fields})
    id.replace("other")
    fields << :extra
    attributes[:extra] = :integer
    expect(resource.id).to eq("example")
    expect(resource.indexes).to eq(label: [:label])
    expect(resource.attributes).to eq(label: :string)
    expect(resource.indexes[:label]).to be_frozen
  end

  [
    {kind: :unknown}, {attributes: {value: :object}}, {attributes: {"value" => :string}},
    {indexes: {anything: [:missing]}}, {indexes: {empty: []}},
    {unique: [{name: :anything, fields: [:missing], where: {}}]},
    {unique: [-> { true }]}, {guard: {resource: "parent", via: -> { "id" }}},
    {kind: :streams, attributes: {value: :string}}, {kind: :blobs, guard: {resource: "parent", via: :key}},
    {attributes: {owner: :string}, guard: {resource: "parent", via: :owner}}
  ].each do |invalid|
    it "rejects unsupported declaration #{invalid.keys.join("/")} before registration" do
      expect { described_class.new(id: "invalid", kind: :records, **invalid) }.to raise_error(ArgumentError)
    end
  end

  it "rejects duplicate IDs, unknown guard resources and mismatched handles" do
    resource = described_class.new(id: "records", kind: :records)
    expect { Phronomy::Storage::Backends::InMemory.new(resources: [resource, resource]) }.to raise_error(Phronomy::Storage::UnsupportedBackendError)
    child = described_class.new(id: "events", kind: :streams, guard: {resource: "missing", via: :stream})
    expect { Phronomy::Storage::Backends::InMemory.new(resources: [child]) }.to raise_error(Phronomy::Storage::UnsupportedBackendError)
    backend = Phronomy::Storage::Backends::InMemory.new(resources: [resource])
    expect { backend.view.streams(resource) }.to raise_error(Phronomy::Storage::UnsupportedBackendError)
    expect { backend.view.records(described_class.new(id: "records", kind: :records)) }.to raise_error(Phronomy::Storage::UnsupportedBackendError)
    expect { Phronomy::Persistence.new(backend: backend) }.to raise_error(Phronomy::Persistence::UnsupportedBackendError)
  end

  it "copies guard and condition references and rejects non-text keys" do
    id = +"records"
    guard = Phronomy::Storage::GuardRef.new(resource: id, key: "key")
    condition = Phronomy::Storage::Condition::RevisionIs.new(resource: id, key: "key", expected: 0)
    id.replace("changed")
    expect(guard.resource).to eq("records")
    expect(condition.resource).to eq("records")
    ["", "\0", "\xff".b, :symbol].each do |key|
      expect { Phronomy::Storage::GuardRef.new(resource: "records", key: key) }.to raise_error(ArgumentError)
    end
  end
end
