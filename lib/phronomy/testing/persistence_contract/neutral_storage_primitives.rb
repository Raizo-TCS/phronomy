# frozen_string_literal: true

require "securerandom"

# This same opaque-record suite runs against InMemory, SQLite and PostgreSQL.
RSpec.shared_examples "neutral storage primitives" do
  let(:raw_backend) { persistence.backend }
  let(:raw_view) { raw_backend.view }
  let(:raw_schema) { Phronomy::Agent::Persistence::StorageSchema }
  let(:raw_record) { Phronomy::Storage::DurableRecord.new(record_type: "unrelated.envelope", format_version: "0.1", payload: {"status" => "ignored"}) }
  let(:raw_owner) { "owner-#{SecureRandom.uuid}" }
  let(:raw_key) { "key-#{SecureRandom.uuid}" }
  let(:raw_records) { raw_view.records(raw_schema::EXECUTIONS) }
  let(:raw_stream) { raw_view.streams(raw_schema::JOURNAL) }
  let(:raw_blobs) { raw_view.blobs(Phronomy::ContentStore::StorageSchema::CONTENTS) }

  def raw_insert(key = raw_key, active: true, owner: raw_owner)
    raw_records.insert(key: key, revision: 0, attributes: {owner: owner, active: active}, record: raw_record)
  end

  before do
    raw_view.records(raw_schema::ROOTS).insert(key: raw_owner, revision: 7, attributes: {}, record: raw_record)
  end

  it "keeps payload opaque and returns independent immutable entries" do
    inserted = raw_insert
    loaded = raw_records.fetch(raw_key)
    expect(loaded).not_to equal(inserted)
    expect(loaded.record).not_to equal(inserted.record)
    expect(loaded.to_h.except(:record)).to eq(inserted.to_h.except(:record))
    expect(loaded).to be_frozen
    expect(loaded.attributes).to be_frozen
    expect(loaded.record.payload).to eq("status" => "ignored")
  end

  it "reports a named conditional unique constraint separately from primary identity" do
    raw_insert
    expect { raw_insert("other") }.to raise_error(Phronomy::Storage::UniqueConstraintError) { |error|
      expect(error.resource).to eq(raw_schema::EXECUTIONS.id)
      expect(error.constraint).to eq(:one_active_owner)
    }
    expect { raw_insert }.to raise_error(Phronomy::Storage::ConflictError) { |error|
      expect(error).not_to be_a(Phronomy::Storage::UniqueConstraintError)
    }
  end

  it "checks revision before active-owner exclusion and retains failed writes" do
    raw_insert
    expect do
      raw_records.replace(key: raw_key, expected_revision: 9, next_revision: 10,
        attributes: {owner: raw_owner, active: false}, record: raw_record)
    end.to raise_error(Phronomy::Storage::ConflictError)
    expect(raw_records.fetch(raw_key).revision).to eq(0)
  end

  it "checks immutable owner and explicit expected attributes" do
    raw_insert
    expect do
      raw_records.replace(key: raw_key, expected_revision: 0, next_revision: 1,
        attributes: {owner: "another", active: true}, record: raw_record)
    end.to raise_error(Phronomy::Storage::ConflictError)
    expect do
      raw_records.replace(key: raw_key, expected_revision: 0, next_revision: 1,
        expected_attributes: {active: false}, attributes: {owner: raw_owner, active: true}, record: raw_record)
    end.to raise_error(Phronomy::Storage::ConflictError)
    expect(raw_records.fetch(raw_key).revision).to eq(0)
  end

  it "keeps active semantics outside Records while enforcing the declared unique rule" do
    raw_insert(active: false)
    raw_insert("competitor")
    expect do
      raw_records.replace(key: raw_key, expected_revision: 0, next_revision: 1,
        attributes: {owner: raw_owner, active: true}, record: raw_record)
    end.to raise_error(Phronomy::Storage::UniqueConstraintError)
    raw_records.replace(key: "competitor", expected_revision: 0, next_revision: 1,
      attributes: {owner: raw_owner, active: false}, record: raw_record)
    expect(raw_records.replace(key: raw_key, expected_revision: 0, next_revision: 1,
      attributes: {owner: raw_owner, active: true}, record: raw_record).revision).to eq(1)
  end

  it "orders equality-index pages by UTF-8 bytes with an exclusive cursor" do
    keys = ["z", "é", "Z", "a"]
    keys.each { |key| raw_insert(key, active: false) }
    sorted = keys.sort_by(&:b)
    first = raw_records.scan(index: :owner, equals: {owner: raw_owner}, limit: 2)
    rest = raw_records.scan(index: :owner, equals: {owner: raw_owner}, after: first.last.key)
    expect((first + rest).map(&:key)).to eq(sorted)
    expect(raw_records.scan(index: :owner_active, equals: {owner: raw_owner, active: true})).to be_empty
  end

  it "validates index shape, limits, attributes and revisions before writing" do
    expect { raw_records.scan(index: :missing, equals: {}) }.to raise_error(ArgumentError)
    expect { raw_records.scan(index: :owner, equals: {active: true}) }.to raise_error(ArgumentError)
    expect { raw_records.scan(index: :owner, equals: {owner: raw_owner}, limit: 0) }.to raise_error(ArgumentError)
    expect { raw_records.insert(key: raw_key, revision: -1, attributes: {owner: raw_owner, active: true}, record: raw_record) }.to raise_error(ArgumentError)
    expect { raw_records.insert(key: raw_key, revision: 0, attributes: {owner: raw_owner, active: "true"}, record: raw_record) }.to raise_error(ArgumentError)
    expect(raw_records.read(raw_key)).to be_nil
  end

  it "requires a parent anchor for child creation, stream append and bulk deletion" do
    expect { raw_insert(owner: "missing-parent") }.to raise_error(Phronomy::Storage::NotFoundError)
    expect { raw_stream.append(stream: "missing-parent", expected_head: 0, entries: []) }.to raise_error(Phronomy::Storage::NotFoundError)
    expect { raw_records.delete_matching(index: :owner, equals: {owner: "missing-parent"}) }.to raise_error(Phronomy::Storage::NotFoundError)
    expect(raw_records.read(raw_key)).to be_nil
  end

  it "separates optional reads, required fetches and revision-checked deletion" do
    expect(raw_records.read(raw_key)).to be_nil
    expect { raw_records.fetch(raw_key) }.to raise_error(Phronomy::Storage::NotFoundError)
    expect { raw_records.delete(key: raw_key, expected_revision: 0) }.to raise_error(Phronomy::Storage::ConflictError)
    expect(raw_records.delete(key: raw_key)).to be_nil
    raw_insert
    expect { raw_records.delete(key: raw_key, expected_revision: 1) }.to raise_error(Phronomy::Storage::ConflictError)
    raw_records.delete(key: raw_key, expected_revision: 0)
    expect(raw_records.read(raw_key)).to be_nil
  end

  it "deletes only the equality-index matches" do
    raw_insert(active: false)
    raw_insert("active")
    raw_records.delete_matching(index: :owner_active, equals: {owner: raw_owner, active: false})
    expect(raw_records.read(raw_key)).to be_nil
    expect(raw_records.fetch("active").attributes[:active]).to be(true)
  end

  it "keeps ordered stream positions, entry IDs and head in one atomic append" do
    entries = %w[first second].map { |id| Phronomy::Storage::Entry::Append.new(id: id, record: raw_record) }
    appended = raw_stream.append(stream: raw_owner, expected_head: 0, entries: entries)
    expect(appended.map(&:position)).to eq([1, 2])
    expect(raw_stream.head(stream: raw_owner)).to eq(2)
    expect(raw_stream.read(stream: raw_owner, after: 1, limit: 1).map(&:id)).to eq(["second"])
    expect { raw_stream.append(stream: raw_owner, expected_head: 2, entries: [entries.first]) }.to raise_error(Phronomy::Storage::ConflictError)
    expect(raw_stream.head(stream: raw_owner)).to eq(2)
    expect(raw_stream.read(stream: raw_owner).map(&:id)).to eq(%w[first second])
  end

  it "checks the head for an empty append and validates duplicate IDs before writing" do
    expect(raw_stream.append(stream: raw_owner, expected_head: 0, entries: [])).to be_empty
    expect { raw_stream.append(stream: raw_owner, expected_head: 1, entries: []) }.to raise_error(Phronomy::Storage::ConflictError)
    entry = Phronomy::Storage::Entry::Append.new(id: "same", record: raw_record)
    expect { raw_stream.append(stream: raw_owner, expected_head: 0, entries: [entry, entry]) }.to raise_error(Phronomy::Storage::ConflictError)
    expect(raw_stream.head(stream: raw_owner)).to eq(0)
  end

  it "deletes a stream's entries and head so identities and positions can be reused" do
    entries = [Phronomy::Storage::Entry::Append.new(id: "reusable", record: raw_record)]
    raw_stream.append(stream: raw_owner, expected_head: 0, entries: entries)
    raw_stream.delete(stream: raw_owner)
    expect(raw_stream.head(stream: raw_owner)).to eq(0)
    expect(raw_stream.read(stream: raw_owner)).to be_empty
    expect(raw_stream.append(stream: raw_owner, expected_head: 0, entries: entries).first.position).to eq(1)
  end

  it "uses arbitrary blob keys, preserves binary bytes and retains first metadata" do
    bytes = "\x00\xffbinary".b
    first = raw_blobs.put_if_absent(key: raw_key, bytes: bytes, attributes: {canonicalization_version: 1})
    second = raw_blobs.put_if_absent(key: raw_key, bytes: bytes, attributes: {canonicalization_version: 99})
    expect(first.attributes).to eq(second.attributes)
    expect(raw_blobs.fetch(raw_key).bytes).to eq(bytes)
    expect { raw_blobs.put_if_absent(key: raw_key, bytes: "other", attributes: {canonicalization_version: 1}) }.to raise_error(Phronomy::Storage::BlobConflictError)
    expect(raw_blobs.fetch(raw_key).bytes).to eq(bytes)
  end

  it "evaluates guarded revision, stream head and no-rows conditions atomically" do
    guard = Phronomy::Storage::GuardRef.new(resource: raw_schema::ROOTS, key: raw_owner)
    revision = Phronomy::Storage::Condition::RevisionIs.new(resource: raw_schema::ROOTS, key: raw_owner, expected: 7)
    head = Phronomy::Storage::Condition::StreamHeadIs.new(resource: raw_schema::JOURNAL, stream: raw_owner, expected: 0)
    idle = Phronomy::Storage::Condition::NoRows.new(resource: raw_schema::EXECUTIONS, index: :owner_active, equals: {owner: raw_owner, active: true})
    expect(raw_view.check!(guards: [guard], conditions: [revision, head, idle])).to be(true)
    expect { raw_view.check!(guards: [], conditions: [head]) }.to raise_error(ArgumentError)
    raw_insert
    expect { raw_view.check!(guards: [guard], conditions: [idle]) }.to raise_error(Phronomy::Storage::ConditionFailedError) { |error| expect(error.condition).to equal(idle) }
  end

  it "rejects a retained bound view and retained handle after commit" do
    saved_view = saved_records = nil
    raw_backend.transaction { |view|
      saved_view = view
      saved_records = view.records(raw_schema::EXECUTIONS)
    }
    expect { saved_view.records(raw_schema::EXECUTIONS) }.to raise_error(Phronomy::Storage::TransactionError)
    expect { saved_records.read(raw_key) }.to raise_error(Phronomy::Storage::TransactionError)
    expect(raw_records.read(raw_key)).to be_nil
  end

  it "rejects a retained bound handle after rollback" do
    handle = nil
    expect do
      raw_backend.transaction { |view|
        handle = view.records(raw_schema::EXECUTIONS)
        raise "abort"
      }
    end.to raise_error("abort")
    expect { handle.read(raw_key) }.to raise_error(Phronomy::Storage::TransactionError)
  end

  it "rejects use of a bound view from another thread" do
    raw_backend.transaction do |view|
      result = Thread.new do
        view.records(raw_schema::EXECUTIONS).read(raw_key)
      rescue => error
        error
      end.value
      expect(result).to be_a(Phronomy::Storage::TransactionError)
      expect(view.records(raw_schema::EXECUTIONS).read(raw_key)).to be_nil
    end
  end

  it "routes cached root handles into the current transaction and rolls back their writes" do
    handle = raw_records
    expect do
      raw_backend.transaction do
        handle.insert(key: raw_key, revision: 0, attributes: {owner: raw_owner, active: true}, record: raw_record)
        raise "rollback"
      end
    end.to raise_error("rollback")
    expect(handle.read(raw_key)).to be_nil
  end

  it "marks a failed physical scope unusable even when the operation error is caught" do
    expect do
      raw_backend.transaction do |view|
        handle = view.records(raw_schema::EXECUTIONS)
        handle.insert(key: raw_key, revision: 0, attributes: {owner: raw_owner, active: true}, record: raw_record)
        expect { handle.insert(key: "collision", revision: 0, attributes: {owner: raw_owner, active: true}, record: raw_record) }.to raise_error(Phronomy::Storage::UniqueConstraintError)
        expect { handle.read(raw_key) }.to raise_error(Phronomy::Storage::TransactionError)
      end
    end.to raise_error(Phronomy::Storage::TransactionError)
    expect(raw_records.read(raw_key)).to be_nil
  end

  [:break, :throw, :return].each do |exit_kind|
    it "rolls back a non-local #{exit_kind} instead of committing" do
      operation = lambda do
        case exit_kind
        when :break
          raw_backend.transaction {
            raw_insert
            break :escaped
          }
        when :throw
          catch(:escape) {
            raw_backend.transaction {
              raw_insert
              throw :escape
            }
          }
        when :return
          returner = -> {
            raw_backend.transaction {
              raw_insert
              return :escaped
            }
          }
          returner.call
        end
      end
      expect { operation.call }.to raise_error(Phronomy::Storage::TransactionError)
      expect(raw_records.read(raw_key)).to be_nil
    end
  end
end
