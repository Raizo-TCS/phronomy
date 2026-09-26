# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Persistence failure boundary" do
  let(:persistence) { Phronomy::Persistence.in_memory }
  let(:backend) { persistence.backend }

  it "loads contracts alone and preserves their identities through later application loading" do
    project_root = File.expand_path("../../..", __dir__)
    source = <<~CODE
      require "phronomy/persistence/contract/state_conflict_error"
      require "phronomy/persistence/contract/not_found_error"
      require "phronomy/persistence/contract/serialization_error"
      require "phronomy/persistence/contract/unsupported_backend_error"
      names = %i[Error ConflictError StateConflictError NotFoundError SerializationError UnsupportedBackendError]
      identities = names.to_h { |name| [name, Phronomy::Persistence.const_get(name)] }
      abort "contract loaded Storage/Engine/Agent" if %i[Storage Runtime Agent].any? { |n| Phronomy.const_defined?(n, false) }
      abort "contract loaded a driver" if $LOADED_FEATURES.any? { |p| p.include?("/phronomy/storage/") }
      require "phronomy"
      Zeitwerk::Loader.eager_load_all
      identities.each { |name, klass| abort "identity replaced" unless Phronomy::Persistence.const_get(name).equal?(klass) }
      abort "backend inheritance leaked" if Phronomy::Persistence::ConflictError < Phronomy::Storage::ConflictError
      abort "Runtime started by loading" if Phronomy::Runtime.default_if_initialized_for_test
      Phronomy::Persistence.in_memory.contents.put_text("works")
      abort "Runtime started by Persistence" if Phronomy::Runtime.default_if_initialized_for_test
    CODE
    output, status = Open3.capture2e({"COVERAGE" => nil, "RUBYOPT" => nil}, RbConfig.ruby,
      "-rbundler/setup", "-I#{project_root}/lib", "-e", source, chdir: project_root)
    expect(status).to be_success, output
  end

  it "keeps the raw backend's public error separate from the domain API" do
    expect { backend.view.records(Phronomy::Agent::Persistence::StorageSchema::ROOTS).fetch("absent") }
      .to raise_error(Phronomy::Storage::NotFoundError)
    expect { persistence.agents.load("absent") }.to raise_error(Phronomy::Persistence::NotFoundError) do |error|
      expect(error).not_to be_a(Phronomy::Storage::NotFoundError)
      expect(error.cause).to be_a(Phronomy::Storage::NotFoundError)
    end
  end

  # Inject at the real raw backend dispatch, not at the already translated repository.
  [:ConflictError, :NotFoundError, :SerializationError, :UnsupportedBackendError].each do |category|
    [:agents, :executions, :teams, :team_executions, :workflow_states, :handoff_states, :journals, :contents].each do |repository|
      it "translates #{category} through #{repository} without losing cause or the original trace" do
        raw = Phronomy::Storage.const_get(category).new("driver failure")
        raw.set_backtrace(["physical_driver.rb:42"])
        allow(backend).to receive(:execute).and_raise(raw)
        operation = case repository
        when :journals then -> { persistence.journals.head("id") }
        when :contents then -> { persistence.contents.fetch("id") }
        else -> { persistence.public_send(repository).load("id") }
        end
        expect(&operation).to raise_error(Phronomy::Persistence.const_get(category)) do |mapped|
          expect(mapped.cause).to equal(raw)
          expect(mapped.message).to eq(raw.message)
          expect(mapped.backtrace).to eq(raw.backtrace)
        end
      end
    end
  end

  [IOError, Phronomy::Storage::TransactionError, Phronomy::AgentBusyError, Phronomy::Persistence::Error].each do |kind|
    it "preserves #{kind} without declaring its outcome known" do
      original = kind.new("unchanged")
      allow(backend).to receive(:execute).and_raise(original)
      expect { persistence.agents.load("id") }.to raise_error { |error| expect(error).to equal(original) }
      expect { persistence.transaction { |tx| tx.contents.fetch("id") } }
        .to raise_error { |error| expect(error).to equal(original) }
    end
  end

  it "keeps translated errors identical when they cross the enclosing transaction boundary" do
    mapped = nil
    expect do
      persistence.transaction do |tx|
        tx.agents.load("absent")
      rescue Phronomy::Persistence::NotFoundError => error
        mapped = error
        raise
      end
    end.to raise_error { |error| expect(error).to equal(mapped) }
  end

  it "distinguishes a domain state conflict and rolls back the caller's write" do
    error = Phronomy::Persistence::StateConflictError.new("owner changed")
    content_id = nil
    expect do
      persistence.transaction do |tx|
        content_id = tx.contents.put_text("discard")
        raise error
      end
    end.to raise_error(Phronomy::Persistence::ConflictError) { |caught| expect(caught).to equal(error) }
    expect(persistence.contents.exist?(content_id)).to be(false)
  end

  it "translates commit rejection after rollback and preserves the enclosing savepoint" do
    raw = Phronomy::Storage::ConflictError.new("commit rejected")
    outer_id = inner_id = nil
    original_transaction = backend.method(:storage_transaction)
    backend.define_singleton_method(:storage_transaction) do |&operation|
      original_transaction.call do |state|
        value = operation.call(state)
        raise raw if Thread.current[:reject_inner_commit]
        value
      end
    end
    persistence.transaction do |outer|
      outer_id = outer.contents.put_text("outer retained")
      begin
        Thread.current[:reject_inner_commit] = true
        expect do
          persistence.transaction do |inner|
            inner_id = inner.contents.put_text("inner discarded")
          end
        end.to raise_error(Phronomy::Persistence::ConflictError) { |e| expect(e.cause).to equal(raw) }
      ensure
        Thread.current[:reject_inner_commit] = nil
      end
      expect(outer.contents.exist?(inner_id)).to be(false)
    end
    expect(persistence.contents.exist?(outer_id)).to be(true)
  end

  it "preserves an unknown error after commit and never retries the write" do
    original = IOError.new("acknowledgement lost")
    backend.define_singleton_method(:transaction) do |&operation|
      super(&operation)
      raise original
    end
    count = 0
    id = nil
    expect do
      persistence.transaction do |tx|
        count += 1
        id = tx.contents.put_text("committed")
      end
    end.to raise_error { |error| expect(error).to equal(original) }
    backend.singleton_class.remove_method(:transaction)
    expect(persistence.contents.exist?(id)).to be(true)
    expect(count).to eq(1)
  end
end
