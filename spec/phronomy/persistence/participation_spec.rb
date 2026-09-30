# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Persistence participation" do
  let(:store) { Phronomy::Persistence.in_memory }
  let(:adapter) { Phronomy::Agent::Persistence::Admission }

  it "rolls all participants back when a later participant fails" do
    ref = nil
    expect do
      store.atomic do |scope|
        scope.participate(persistence: store, adapter: adapter) { |records| ref = records.contents.put_text("provisional") }
        scope.participate(persistence: store, adapter: adapter) { raise IOError, "write failed" }
      end
    end.to raise_error(IOError, "write failed")
    expect(store.contents.exist?(ref)).to be(false)
  end

  it "rejects a different Persistence even when it wraps the same backend" do
    other = Phronomy::Persistence.new(backend: store.backend)
    expect do
      store.atomic { |scope| scope.participate(persistence: other, adapter: adapter) { raise "must not run" } }
    end.to raise_error(Phronomy::Persistence::TransactionError, /same open/)
  end

  it "rejects retained scopes and worker transfer" do
    captured = nil
    store.atomic do |scope|
      captured = scope
      failure = Thread.new do
        scope.participate(persistence: store, adapter: adapter) { raise "must not run" }
      rescue => error
        error
      end.value
      expect(failure).to be_a(Phronomy::Persistence::TransactionError)
    end
    expect { captured.participate(persistence: store, adapter: adapter) {} }
      .to raise_error(Phronomy::Persistence::TransactionError)
  end

  it "does not allow a rescued participation failure to commit earlier writes" do
    ref = nil
    expect do
      store.atomic do |scope|
        scope.participate(persistence: store, adapter: adapter) { |records| ref = records.contents.put_text("poisoned") }
        begin
          scope.participate(persistence: store, adapter: adapter) { raise "failed participant" }
        rescue RuntimeError
          nil
        end
      end
    end.to raise_error(Phronomy::Persistence::TransactionError)
    expect(store.contents.exist?(ref)).to be(false)
  end

  it "keeps successful savepoints provisional and rolls them back with their parent" do
    inner = ref = nil
    expect do
      store.atomic do
        store.atomic do |scope|
          inner = scope
          scope.participate(persistence: store, adapter: adapter) { |records| ref = records.contents.put_text("inner") }
        end
        expect(inner.committed?).to be(false)
        raise "outer failed"
      end
    end.to raise_error("outer failed")
    expect(inner.committed?).to be(false)
    expect(store.contents.exist?(ref)).to be(false)
  end

  it "confirms an inner scope only after the outermost commit response" do
    inner = nil
    store.atomic do
      store.atomic { |scope| inner = scope }
      expect(inner.committed?).to be(false)
    end
    expect(inner.committed?).to be(true)
  end

  it "does not claim commit ownership inside a raw backend transaction" do
    expect { store.backend.transaction { store.atomic {} } }
      .to raise_error(Phronomy::Persistence::TransactionError, /commit ownership/)
  end

  it "keeps a lost commit response unknown even if the backend saved the data" do
    scope = ref = nil
    allow(store.backend).to receive(:transaction).and_wrap_original do |original, &block|
      original.call(&block)
      raise IOError, "commit response lost"
    end
    expect do
      store.atomic do |current|
        scope = current
        current.participate(persistence: store, adapter: adapter) { |records| ref = records.contents.put_text("saved") }
      end
    end.to raise_error(IOError, "commit response lost")
    expect(scope.committed?).to be(false)
    allow(store.backend).to receive(:transaction).and_call_original
    expect(store.contents.exist?(ref)).to be(true)
  end
end
