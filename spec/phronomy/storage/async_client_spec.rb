# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Storage::AsyncClient do
  let(:sync_backend) { Phronomy::Storage::Backends::InMemory.new }
  let(:sync_operation) { :transaction }

  def build_client(pool: nil)
    described_class.new(backend: sync_backend, pool: pool)
  end

  def invoke_async(instance, token: nil, timeout: nil)
    instance.transaction_async(cancellation_token: token, timeout: timeout) { [] }
  end

  it_behaves_like "an asynchronous backend client"

  it "rejects a missing transaction block before starting Runtime" do
    instance = build_client
    expect { instance.transaction_async }.to raise_error(ArgumentError, /requires a block/)
    expect(Phronomy::Runtime.default_if_initialized_for_test).to be_nil
  end

  it "accepts a synchronous SPI backend without inheritance or async methods" do
    delegate = sync_backend
    backend = Object.new
    backend.define_singleton_method(:capabilities) { delegate.capabilities }
    backend.define_singleton_method(:view) { delegate.view }
    backend.define_singleton_method(:transaction) { |&work| delegate.transaction(&work) }
    value = Object.new
    result = described_class.new(backend: backend).transaction_async { value }.wait_result(timeout: 2)
    expect(result).to equal(value)
    expect(backend).not_to respond_to(:transaction_async)
  end

  describe "transaction lifetime and atomicity" do
    let(:records) { Phronomy::Storage::Resource.new(id: "async.records", kind: :records) }
    let(:streams) { Phronomy::Storage::Resource.new(id: "async.streams", kind: :streams) }
    let(:blobs) { Phronomy::Storage::Resource.new(id: "async.blobs", kind: :blobs) }
    let(:backend) { Phronomy::Storage::Backends::InMemory.new(resources: [records, streams, blobs]) }
    let(:timer) { Phronomy::Testing::FakeClock.new }
    let(:pool) do
      Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 4, timer_queue_provider: -> { timer })
    end
    let(:client) { described_class.new(backend: backend, pool: pool) }
    after { pool.shutdown(drain_timeout: 2) }

    def record
      Phronomy::Storage::DurableRecord.new(record_type: "async.example", format_version: "0.1", payload: {"value" => 1})
    end

    def insert(view, key)
      view.records(records).insert(key: key, revision: 1, attributes: {}, record: record)
    end

    def write_all(view)
      insert(view, "entry")
      entry = Phronomy::Storage::Entry::Append.new(id: "event", record: record)
      view.streams(streams).append(stream: "events", expected_head: 0, entries: [entry])
      view.blobs(blobs).put_if_absent(key: "bytes", bytes: "content", attributes: {})
    end

    it "opens, executes and closes on the same worker and commits all resources before success" do
      observed = []
      allow(backend).to receive(:transaction).and_wrap_original do |method, &work|
        observed << Thread.current
        result = method.call(&work)
        observed << Thread.current
        expect(backend.current_view).to be_nil
        result
      end
      task = client.transaction_async do |view|
        observed << Thread.current
        write_all(view)
        :committed
      end
      expect(task.wait_result(timeout: 2)).to eq(:committed)
      expect(observed.size).to eq(3)
      expect(observed.uniq.size).to eq(1)
      expect(observed.first).not_to equal(Thread.current)
      expect(backend.view.records(records).fetch("entry").revision).to eq(1)
      expect(backend.view.streams(streams).head(stream: "events")).to eq(1)
      expect(backend.view.blobs(blobs).fetch("bytes").bytes).to eq("content")
    end

    it "rolls back records, streams and blobs on the original block failure" do
      error = IOError.new("write failed")
      task = client.transaction_async { |view|
        write_all(view)
        raise error
      }
      expect { task.wait_result(timeout: 2) }.to raise_error { |actual| expect(actual).to equal(error) }
      expect(backend.view.records(records).read("entry")).to be_nil
      expect(backend.view.streams(streams).head(stream: "events")).to eq(0)
      expect(backend.view.blobs(blobs).exist?("bytes")).to be(false)
      expect(pool.submit { backend.current_view }.wait_result(timeout: 2)).to be_nil
    end

    it "keeps nested savepoints on the same worker and rolls back only the failed inner scope" do
      client.transaction_async do |view|
        insert(view, "outer")
        begin
          backend.transaction do |inner|
            expect(Thread.current.name).to match(/offload-pool/)
            insert(inner, "inner")
            raise IOError, "inner failed"
          end
        rescue IOError
          insert(view, "after")
        end
      end.wait_result(timeout: 2)
      expect(backend.view.records(records).read("outer")).not_to be_nil
      expect(backend.view.records(records).read("after")).not_to be_nil
      expect(backend.view.records(records).read("inner")).to be_nil
    end

    it "rolls back successful inner work when the outer transaction fails" do
      task = client.transaction_async do |view|
        insert(view, "outer")
        backend.transaction { |inner| insert(inner, "inner") }
        raise IOError, "outer failed"
      end
      expect { task.wait_result(timeout: 2) }.to raise_error(IOError, /outer failed/)
      expect(backend.view.records(records).read("outer")).to be_nil
      expect(backend.view.records(records).read("inner")).to be_nil
    end

    it "does not let a bound transaction view escape its worker or its lifetime" do
      view = client.transaction_async { |bound| bound }.wait_result(timeout: 2)
      expect { view.records(records) }.to raise_error(Phronomy::Storage::TransactionError, /another execution context/)
      task = pool.submit { view.records(records) }
      expect { task.wait_result(timeout: 2) }.to raise_error(Phronomy::Storage::TransactionError, /scope is closed/)
    end

    it "rolls back a non-local break instead of committing partial work" do
      work = proc do |view|
        insert(view, "entry")
        break :escaped
      end
      task = client.transaction_async(&work)
      expect { task.wait_result(timeout: 2) }.to raise_error(LocalJumpError)
      expect(backend.view.records(records).read("entry")).to be_nil
      expect(pool.submit { backend.current_view }.wait_result(timeout: 2)).to be_nil
    end

    [:timeout, :cancellation].each do |reason|
      it "does not report rollback when running #{reason} leaves a physical commit in progress" do
        started, release, committed = Queue.new, Queue.new, Queue.new
        token = Phronomy::Concurrency::CancellationToken.new
        allow(backend).to receive(:transaction).and_wrap_original do |method, &work|
          result = method.call(&work)
          committed << true
          result
        end
        task = client.transaction_async(cancellation_token: token, timeout: (reason == :timeout) ? 5 : nil) do |view|
          insert(view, "entry")
          started << true
          release.pop
          :saved
        end
        expect(started.pop(timeout: 2)).to be(true)
        (reason == :timeout) ? timer.advance(5) : token.cancel!
        error = (reason == :timeout) ? Phronomy::TimeoutError : Phronomy::CancellationError
        expect { task.wait_result(timeout: 2) }.to raise_error(error)
        expect(committed).to be_empty
        release << true
        pool.shutdown(drain_timeout: 2)
        expect(committed.pop(timeout: 2)).to be(true)
        expect(backend.view.records(records).read("entry")).not_to be_nil
        expect { task.wait_result }.to raise_error(error)
      ensure
        release&.push(true)
      end
    end
  end

  describe "internal synchronous storage submission" do
    let(:pool) { Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 2) }
    after { pool.shutdown(drain_timeout: 2) }

    it "submits exactly once without wrapping existing work in another transaction" do
      backend = sync_backend
      expect(backend).to receive(:transaction).once.and_call_original
      original = nil
      expect(pool).to receive(:submit).once.with(on_full: :raise).and_wrap_original do |method, **options, &work|
        original = method.call(**options, &work)
      end
      task = described_class.submit(pool: pool) { backend.transaction { :saved } }
      expect(task).to equal(original)
      expect(task.wait_result(timeout: 2)).to eq(:saved)
    end

    it "keeps commit-response loss as the original error and leaves reconciliation to the owner" do
      backend = sync_backend
      response_lost = IOError.new("commit response lost")
      expect(backend).to receive(:transaction).once.and_wrap_original do |method, &work|
        method.call(&work)
        raise response_lost
      end
      task = described_class.submit(pool: pool) { backend.transaction { :saved } }
      expect { task.wait_result(timeout: 2) }.to raise_error { |error| expect(error).to equal(response_lost) }
    end
  end
end
