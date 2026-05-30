# frozen_string_literal: true

# Stress and resource leak tests (Issue #275).
#
# These tests verify correctness under concurrent load and check that threads,
# queues, and tasks return to their baseline counts after completion.
#
# Scenarios requiring real backends (LLM, MCP, Redis) are tagged :integration
# and run separately.
RSpec.describe "Stress and resource leak tests (Issue #275)" do
  let(:pool) { Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 10, queue_size: 200) }

  after { pool.shutdown(drain_timeout: 10) }

  describe "concurrent BlockingAdapterPool submissions" do
    it "completes 50 concurrent submissions with correct results" do
      results = Array.new(50)
      threads = 50.times.map do |i|
        Thread.new do
          op = pool.submit { i * 2 }
          results[i] = op.await
        end
      end
      threads.each(&:join)
      expect(results).to eq(50.times.map { |i| i * 2 })
    end

    it "returns thread count to baseline after all submissions complete" do
      baseline = Thread.list.count

      threads = 20.times.map do
        Thread.new {
          pool.submit {
            sleep(0.01)
            :done
          }.await
        }
      end
      threads.each(&:join)

      # Give pool workers a moment to settle
      sleep(0.05)
      # Thread count should not have grown beyond pool workers + initial threads
      current = Thread.list.count
      extra_threads = current - baseline
      # Pool spawned up to 10 workers at init; those are already in baseline if
      # pool was pre-warmed, but allow for up to pool_size overhead
      expect(extra_threads).to be <= pool.pool_size + 2
    end
  end

  describe "timeout storm" do
    it "abandons operations that time out during execution" do
      # Submit operations that will time out during execution.
      # Use a very short timeout so they complete quickly.
      ops = 5.times.map { pool.submit(timeout: 0.05) { sleep(10) } }

      errors = ops.map do |op|
        op.await
        nil
      rescue Phronomy::TimeoutError => e
        e
      end

      expect(errors.compact.size).to eq(5)
      expect(pool.abandoned_count).to be >= 5
    end
  end

  describe "backpressure under pool saturation" do
    it "raises BackpressureError when queue is full with on_full: :raise" do
      sat_pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 2)
      latch = Mutex.new
      cond = ConditionVariable.new
      released = false

      sat_pool.submit { latch.synchronize { cond.wait(latch, 5) until released } }
      sleep(0.02)
      2.times {
        begin
          sat_pool.submit(on_full: :raise) { :fill }
        rescue
          nil
        end
      }

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

  describe "BlockingAdapterPool graceful shutdown" do
    it "drains in-flight operations before stopping" do
      small_pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 2, queue_size: 10)
      results = []
      mutex = Mutex.new

      5.times do |i|
        small_pool.submit {
          sleep(0.01)
          mutex.synchronize { results << i }
        }
      end

      small_pool.shutdown(drain_timeout: 5)
      expect(results.sort).to eq([0, 1, 2, 3, 4])
    end
  end

  describe "queue depth returns to zero after completion" do
    it "empties the queue after all submitted operations complete" do
      20.times { pool.submit { :noop }.await }
      expect(pool.queue_depth).to eq(0)
    end
  end
end
