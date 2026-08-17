# frozen_string_literal: true

# Backend failure scenario tests (Issue #274).
#
# Covers failure modes that do not require real backends (Redis, Pgvector, LLM).
# Real-backend smoke tests (requiring Docker services) are deferred to the
# integration suite and depend on CI infra work tracked in #274.
#
# External Knowledge acquisition is application / Tool responsibility. Backend
# timeout coverage therefore belongs to concrete acquisition primitives such as
# Embeddings and VectorStore rather than to an Agent KnowledgeSource abstraction.
#
# Scenarios covered here:
#   - Network timeout during Embeddings#embed_async
#   - Network timeout during VectorStore#search_async
#   - Cancellation during in-flight OffloadPool operation
#   - OffloadPool saturation — backpressure, not silent drop
#   - Scheduler lag remains low while slow backend blocks pool workers
RSpec.describe "Backend failure scenarios (Issue #274)" do
  describe "Embeddings network timeout" do
    let(:embedder) do
      Class.new(Phronomy::VectorStore::Embeddings::Base) do
        def embed(text, _cancellation_token = nil)
          sleep(10)
          [0.1, 0.2]
        end
      end.new
    end

    it "raises TimeoutError via embed_async when backend hangs" do
      op = embedder.embed_async("hello", timeout: 0.1)
      expect { op.wait_result }.to raise_error(Phronomy::TimeoutError)
    end
  end

  describe "VectorStore network timeout" do
    let(:vs) do
      Class.new(Phronomy::VectorStore::Base) do
        def search(query_embedding:, k: 5, cancellation_token: nil)
          sleep(10)
          []
        end
      end.new
    end

    it "raises TimeoutError via search_async when backend hangs" do
      op = vs.search_async(query_embedding: [0.1], k: 3, timeout: 0.1)
      expect { op.wait_result }.to raise_error(Phronomy::TimeoutError)
    end
  end

  describe "Cancellation during in-flight operation" do
    let(:pool) { Phronomy::Concurrency::OffloadPool.new(pool_size: 2, queue_size: 10) }

    after { pool.shutdown(drain_timeout: 5) }

    it "raises CancellationError when token is cancelled before execution" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!

      op = pool.submit(cancellation_token: token) { "should not run" }
      expect { op.wait_result }.to raise_error(Phronomy::CancellationError)
    end
  end

  describe "OffloadPool saturation — no silent drop" do
    it "raises BackpressureError (not silently drops) when queue is full" do
      sat_pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 1, queue_size: 1)
      latch = Mutex.new
      cond = ConditionVariable.new
      released = false

      # Occupy the single worker
      sat_pool.submit { latch.synchronize { cond.wait(latch, 5) until released } }
      sleep(0.02)
      # Fill the queue
      begin
        sat_pool.submit(on_full: :raise) { :fill }
      rescue
        nil
      end

      expect {
        sat_pool.submit(on_full: :raise) { :overflow }
      }.to raise_error(Phronomy::BackpressureError)
    ensure
      latch.synchronize {
        released = true
        cond.broadcast
      }
      sat_pool.shutdown(drain_timeout: 2)
    end
  end

  describe "Scheduler lag under slow-backend load" do
    it "keeps EventLoop max_lag_seconds below 0.2s while pool workers are busy" do
      pool = Phronomy::Concurrency::OffloadPool.new(pool_size: 4, queue_size: 20)
      runtime = Phronomy::Runtime.new
      el = runtime.event_loop

      begin
        # Submit slow operations to occupy pool workers
        ops = 4.times.map { pool.submit { sleep(0.1) } }

        # Wait for ops to finish
        ops.each(&:wait_result)
        sleep(0.05)

        expect(el.max_lag_seconds).to be < 0.2
      ensure
        begin
          runtime.shutdown(timeout: 2)
        rescue
          nil
        end
        pool.shutdown(drain_timeout: 5)
      end
    end
  end
end
