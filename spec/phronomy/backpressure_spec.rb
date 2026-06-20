# frozen_string_literal: true

RSpec.describe "Backpressure limits (Issue #268)" do
  describe "BlockingAdapterPool#submit" do
    context "on_full: :raise" do
      it "raises BackpressureError when queue is full" do
        # pool_size: 1, queue_size: 1
        # Worker picks up op1 immediately (queue goes 1->0).
        # op2 fills the queue (depth: 1).
        # op3 should raise BackpressureError.
        pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 1)
        latch = Mutex.new
        cond = ConditionVariable.new
        released = false

        # op1: held in worker
        pool.submit { latch.synchronize { cond.wait(latch, 5) until released } }
        # Give the worker a moment to dequeue op1 so the queue is empty
        sleep(0.02)
        # op2: sits in queue
        pool.submit(on_full: :raise) { :second }
        # op3: queue full -> BackpressureError
        expect {
          pool.submit(on_full: :raise) { :overflow }
        }.to raise_error(Phronomy::BackpressureError)
      ensure
        latch.synchronize {
          released = true
          cond.broadcast
        }
        pool.shutdown(drain_timeout: 2)
      end
    end

    context "on_full: :timeout" do
      it "raises TimeoutError when queue is full and wait exceeds timeout" do
        pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 1)
        latch = Mutex.new
        cond = ConditionVariable.new
        released = false

        pool.submit { latch.synchronize { cond.wait(latch, 5) until released } }
        sleep(0.02)
        pool.submit(on_full: :raise) { :second }

        expect {
          pool.submit(on_full: :timeout, full_timeout: 0.05) { :overflow }
        }.to raise_error(Phronomy::TimeoutError)
      ensure
        latch.synchronize {
          released = true
          cond.broadcast
        }
        pool.shutdown(drain_timeout: 2)
      end
    end

    context "on_full: :wait (default)" do
      it "blocks until a slot is available and returns successfully" do
        pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 1, queue_size: 1)
        barrier = Mutex.new
        cond = ConditionVariable.new
        released = false

        op1 = pool.submit {
          barrier.synchronize { cond.wait(barrier, 2) until released }
          :first
        }
        # Fill queue with on_full: :raise to skip; then release for the wait test
        Thread.new do
          sleep(0.02)
          barrier.synchronize {
            released = true
            cond.broadcast
          }
        end

        op2 = pool.submit(on_full: :wait) { :second }
        result = op2.wait_result
        expect(result).to eq(:second)
        op1.wait_result
      ensure
        pool.shutdown(drain_timeout: 2)
      end
    end
  end

  describe "Phronomy::Configuration" do
    it "defaults backpressure to :wait" do
      config = Phronomy::Configuration.new
      expect(config.backpressure).to eq(:wait)
    end

    it "allows backpressure to be set to :raise" do
      config = Phronomy::Configuration.new
      config.backpressure = :raise
      expect(config.backpressure).to eq(:raise)
    end

    it "allows backpressure_timeout to be configured" do
      config = Phronomy::Configuration.new
      config.backpressure = :timeout
      config.backpressure_timeout = 5.0
      expect(config.backpressure_timeout).to eq(5.0)
    end
  end

  describe "Phronomy::BackpressureError" do
    it "is a subclass of Phronomy::Error" do
      expect(Phronomy::BackpressureError.ancestors).to include(Phronomy::Error)
    end
  end
end
