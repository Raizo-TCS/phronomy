# frozen_string_literal: true

module Phronomy
  # A bounded, observable thread pool for blocking I/O operations.
  #
  # All blocking calls (LLM HTTP, MCP stdio, ActiveRecord, Redis, etc.) must be
  # submitted through this pool so that:
  #
  # 1. The total number of OS threads is capped.
  # 2. Queue depth is bounded (backpressure when the pool is saturated).
  # 3. Per-operation timeouts are enforced consistently.
  # 4. Abandoned (timed-out) operations are tracked and logged.
  # 5. Metrics (active count, queue depth, abandoned count, avg wait time) are
  #    observable at runtime.
  #
  # @example Submitting a blocking LLM call
  #   op = runtime.blocking_io.submit(timeout: 30) { chat.ask(message) }
  #   result = op.await   # blocks the calling thread until done
  #
  # @example With cancellation
  #   token = Phronomy::CancellationToken.timeout_after(60)
  #   op = pool.submit(timeout: 30, cancellation_token: token) { expensive_call }
  #   result = op.await
  class BlockingAdapterPool
    # Represents the pending result of a submitted blocking operation.
    # Returned immediately by {BlockingAdapterPool#submit}; call {#await} to
    # wait for the result.
    class PendingOperation
      # @return [Boolean] true when the operation has finished (success or error)
      def done?
        @mutex.synchronize { @done }
      end

      # @return [Boolean] true when the operation was abandoned due to timeout
      def abandoned?
        @abandoned
      end

      # @return [Float] seconds spent in the queue before execution started
      def wait_time
        @wait_time || 0.0
      end

      # Blocks until the operation completes and returns its value.
      # If a +timeout+ was given to {BlockingAdapterPool#submit}, the caller
      # stops waiting after that many seconds and a {Phronomy::TimeoutError}
      # is raised.  The worker thread is NOT interrupted — it runs to
      # completion on its own, which avoids the data-corruption risk of
      # async +Thread#raise+ from +Timeout.timeout+.
      #
      # @return [Object]
      # @raise [Exception]
      def await
        if @timeout
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
          @mutex.synchronize do
            until @done
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if remaining <= 0
                @abandoned = true
                @on_abandoned&.call
                raise Phronomy::TimeoutError, "blocking operation timed out after #{@timeout}s"
              end
              @cond.wait(@mutex, remaining)
            end
          end
        else
          @mutex.synchronize { @cond.wait(@mutex) until @done }
        end
        raise @error if @error

        @value
      end

      # @api private
      def initialize(block, timeout: nil, cancellation_token: nil, on_abandoned: nil)
        @block = block
        @timeout = timeout
        @cancellation_token = cancellation_token
        @on_abandoned = on_abandoned
        @value = nil
        @error = nil
        @done = false
        @abandoned = false
        @wait_time = nil
        @submitted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex = Mutex.new
        @cond = ConditionVariable.new
      end

      # @api private
      def execute!
        @wait_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @submitted_at

        if @cancellation_token&.cancelled?
          complete_with_error!(CancellationError.new("operation cancelled before execution"))
          return
        end

        # Do NOT use Timeout.timeout here — it delivers an async Thread#raise
        # that can corrupt external library state (mutexes, C extensions, etc.).
        # Timeout enforcement is handled cooperatively in #await instead.
        # Each blocking library (Net::HTTP, pg, redis, etc.) should set its
        # own native connection/read timeouts.
        begin
          complete_with_value!(@block.call)
        rescue => e
          complete_with_error!(e)
        end
      end

      private

      def complete_with_value!(value)
        @mutex.synchronize do
          @value = value
          @done = true
          @cond.broadcast
        end
      end

      def complete_with_error!(error)
        @mutex.synchronize do
          @error = error
          @done = true
          @cond.broadcast
        end
      end
    end

    # @param pool_size  [Integer] maximum number of worker threads
    # @param queue_size [Integer] maximum pending operations waiting for a worker
    # @param name       [String, Symbol, nil] optional pool name used in thread labels
    # @param logger     [Logger, nil] optional logger for warnings
    def initialize(pool_size: 10, queue_size: 100, name: nil, logger: nil)
      @pool_size = pool_size
      @queue_size = queue_size
      @name = name
      @logger = logger
      @queue = SizedQueue.new(queue_size)
      @active_count = 0
      @abandoned_count = 0
      @total_wait_ns = 0
      @completed_count = 0
      @mutex = Mutex.new
      @shutdown = false
      @workers = Array.new(pool_size) { |i| spawn_worker(i) }
    end

    # Submits a blocking operation to the pool.
    # Returns a {PendingOperation} immediately; the block runs on a worker thread.
    #
    # @param timeout [Numeric, nil] seconds before the operation is abandoned
    # @param cancellation_token [CancellationToken, nil]
    # @yield block containing the blocking call
    # @return [PendingOperation]
    # @raise [Phronomy::PoolShutdownError] when the pool has been shut down
    # @raise [Phronomy::BackpressureError] when +on_full: :raise+ and queue is full
    # @raise [Phronomy::TimeoutError] when +on_full: :timeout+ and wait exceeds +full_timeout+
    def submit(timeout: nil, cancellation_token: nil, on_full: :wait, full_timeout: nil, &block)
      raise Phronomy::PoolShutdownError, "pool has been shut down" if @shutdown

      op = PendingOperation.new(block, timeout: timeout, cancellation_token: cancellation_token,
        on_abandoned: timeout ? -> { @mutex.synchronize { @abandoned_count += 1 } } : nil)
      case on_full
      when :raise
        begin
          @queue.push(op, true)
        rescue ThreadError
          raise Phronomy::BackpressureError, "BlockingAdapterPool queue is full (depth: #{@queue_size})"
        end
      when :timeout
        deadline = full_timeout ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) + full_timeout) : nil
        loop do
          @queue.push(op, true)
          break
        rescue ThreadError
          if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise Phronomy::TimeoutError, "timed out waiting for a free slot in BlockingAdapterPool"
          end
          sleep(0.005)
        end
      else # :wait (default)
        @queue.push(op)
      end
      op
    end

    # Gracefully drains the pool and terminates all worker threads.
    # Waits up to +drain_timeout+ seconds for in-flight operations to finish.
    #
    # @param drain_timeout [Numeric] seconds to wait for workers to finish
    # @return [self]
    def shutdown(drain_timeout: 30)
      @shutdown = true
      @pool_size.times { @queue.push(:shutdown) }
      @workers.each { |t| t.join(drain_timeout) }
      self
    end

    # --- Metrics ----------------------------------------------------------

    # @return [Integer] number of operations currently executing on workers
    def active_count
      @mutex.synchronize { @active_count }
    end

    # @return [Integer] number of operations waiting in the queue
    def queue_depth
      @queue.size
    end

    # @return [Integer] number of operations that were abandoned due to timeout
    def abandoned_count
      @mutex.synchronize { @abandoned_count }
    end

    # Average time (in seconds) that completed operations spent in the queue
    # waiting for a worker.  Returns 0.0 when no operations have completed yet.
    # @return [Float]
    def average_wait_seconds
      @mutex.synchronize do
        return 0.0 if @completed_count.zero?

        @total_wait_ns / @completed_count.to_f / 1_000_000_000.0
      end
    end

    # @return [Integer] configured maximum number of worker threads
    attr_reader :pool_size

    # @return [Integer] configured maximum queue depth
    attr_reader :queue_size

    # @return [String, Symbol, nil] pool name used in thread labels
    attr_reader :name

    private

    SENTINEL = :shutdown
    private_constant :SENTINEL

    def spawn_worker(index = nil)
      label = ["phronomy", "blocking-pool", @name, index].compact.join("-")
      Thread.new do
        Thread.current.name = label
        loop do
          op = @queue.pop
          break if op == SENTINEL

          run_operation(op)
        end
      end
    end

    def run_operation(op)
      @mutex.synchronize { @active_count += 1 }

      begin
        op.execute!
      ensure
        @mutex.synchronize do
          @active_count -= 1

          if op.abandoned?
            @logger&.warn { "BlockingAdapterPool: worker finished operation after caller timed out" }
          end

          @total_wait_ns += (op.wait_time * 1_000_000_000).to_i
          @completed_count += 1
        end
      end
    end
  end
end
