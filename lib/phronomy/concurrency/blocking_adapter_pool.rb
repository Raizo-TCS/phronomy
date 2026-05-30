# frozen_string_literal: true

module Phronomy
  module Concurrency
    # A bounded, observable thread pool for blocking I/O operations.
    #
    # ## Architectural boundary
    #
    # `BlockingAdapterPool` is the *only* place in Phronomy that uses raw OS threads
    # for I/O. All third-party gem calls whose internal I/O Phronomy cannot control
    # — including RubyLLM, ActiveRecord, Redis, Faraday, and MCP stdio transport —
    # **must** route through this pool (or a named pool obtained via
    # {Runtime#pool}). Custom non-blocking HTTP/selector runtimes are intentionally
    # out of scope; the pool + cooperative scheduler combination satisfies all
    # current concurrency requirements without that complexity. (See ADR-010.)
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
    #   token = Phronomy::Concurrency::CancellationToken.timeout_after(60)
    #   op = pool.submit(timeout: 30, cancellation_token: token) { expensive_call }
    #   result = op.await
    class BlockingAdapterPool
      # Represents the pending result of a submitted blocking operation.
      # Returned immediately by {BlockingAdapterPool#submit}; call {#await} to
      # wait for the result.
      class PendingOperation
        # @return [Boolean] true when the operation has finished (success or error)
        # @api private
        def done?
          @mutex.synchronize { @done }
        end

        # @return [Boolean] true when the operation was abandoned due to timeout
        # @api private
        def abandoned?
          @abandoned
        end

        # @return [Float] seconds spent in the queue before execution started
        # @api private
        def wait_time
          @wait_time || 0.0
        end

        # Blocks until the operation completes and returns its value.
        #
        # An optional +timeout+ (in seconds) may be passed here; it is measured
        # from the moment +await+ is called. If both a submit-time timeout and an
        # await-time timeout are present, the earlier deadline wins. The worker
        # thread is NOT interrupted — it runs to completion on its own.
        #
        # An optional +cancellation_token+ may be passed here (or at submit time).
        # If the token is cancelled while waiting, {Phronomy::CancellationError} is
        # raised immediately without interrupting the worker.
        #
        # **Cooperative path (`:fiber` / `DeterministicScheduler`):**
        # When called from a Fiber managed by {DeterministicScheduler} (i.e. under
        # the +:fiber+ runtime backend), the calling Fiber suspends cooperatively
        # via +Fiber.yield+ rather than blocking the OS thread.  The Fiber is
        # resumed on the scheduler's ready queue once the worker thread completes
        # the operation.
        #
        # @note **Cooperative cancellation semantics** (ADR-010):
        #   Phronomy uses a non-preemptive, cooperative-first concurrency model.
        #   Cancellation is *cooperative*, not preemptive:
        #   - When a +cancellation_token+ is cancelled, +CancellationError+ is
        #     raised to the +await+ caller immediately; when the timeout fires,
        #     +TimeoutError+ is raised instead. In both cases, the underlying
        #     worker thread is **not** forcibly stopped.
        #   - The worker thread will complete its submitted block naturally.
        #     Code inside the block must call +token.check!+ at suitable
        #     checkpoints to observe the cancelled state and exit early.
        #   - There is no +Thread#kill+ or +Thread#raise+ involved. The framework
        #     never forcibly terminates worker threads.
        #
        # @note **Cooperative timeout limitation**: the +timeout:+ parameter passed
        #   to +await+ is *not* enforced on the cooperative path.  The calling Fiber
        #   remains suspended until the worker thread finishes regardless of how many
        #   seconds elapse.  This is because the cooperative scheduler cannot
        #   preempt a running OS thread.  If a time bound is required, set
        #   +timeout:+ at {BlockingAdapterPool#submit submit} time instead; the pool
        #   will then abandon the operation on the worker side and mark it as
        #   {#abandoned?}.
        #
        # @param timeout [Numeric, nil] seconds from now before raising TimeoutError
        #   (thread path only; ignored on the cooperative/fiber path)
        # @param cancellation_token [CancellationToken, nil]
        # @return [Object]
        # @raise [Phronomy::TimeoutError]
        # @raise [Phronomy::CancellationError]
        # @raise [Exception] error raised inside the submitted block
        # @api private
        def await(timeout: nil, cancellation_token: nil)
          effective_timeout = [timeout, @timeout].compact.min
          effective_token = cancellation_token || @cancellation_token

          raise CancellationError, "blocking operation cancelled" if effective_token&.cancelled?

          # Cooperative context: suspend the calling Fiber rather than blocking
          # the OS thread so that DeterministicScheduler can continue dispatching
          # other tasks while waiting for the blocking worker to finish.
          # (Issue #338, ADR-010 Rule 3)
          # Uses the same thread-local key as Task::FiberBackend::SCHEDULER_KEY
          # (:phronomy_deterministic_scheduler) to avoid a cross-file constant
          # dependency at load time.
          scheduler = Thread.current.thread_variable_get(:phronomy_deterministic_scheduler)
          in_managed_fiber = !Fiber.respond_to?(:main) || Fiber.current != Fiber.main
          if scheduler && in_managed_fiber
            unless @done
              # Register this await with the scheduler so run_until_idle knows
              # not to exit until the worker thread completes (Issue #338).
              scheduler.track_blocking_await
              waiting_fiber = Fiber.current
              on_complete do |_result, _error|
                # Decrement the counter and wake run_until_idle, then re-enqueue
                # the suspended Fiber for cooperative resumption.
                scheduler.complete_blocking_await
                scheduler.enqueue_fiber(-> { waiting_fiber.resume })
              end
              Fiber.yield(:cooperative_suspend)
            end
            raise CancellationError, "blocking operation cancelled" if effective_token&.cancelled?
            raise @error if @error

            return @value
          end

          # Wake up the waiting thread whenever the token is cancelled so we can
          # propagate cancellation without sleeping until the timeout expires.
          effective_token&.on_cancel { @mutex.synchronize { @cond.broadcast } }

          if effective_timeout
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + effective_timeout
            @mutex.synchronize do
              until @done
                raise CancellationError, "blocking operation cancelled" if effective_token&.cancelled?

                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if remaining <= 0
                  # Guard against double-counting when await is called multiple times.
                  unless @abandoned
                    @abandoned = true
                    @on_abandoned&.call
                  end
                  raise Phronomy::TimeoutError, "blocking operation timed out after #{effective_timeout}s"
                end
                @cond.wait(@mutex, remaining)
              end
            end
          else
            @mutex.synchronize do
              until @done
                raise CancellationError, "blocking operation cancelled" if effective_token&.cancelled?

                @cond.wait(@mutex)
              end
            end
          end
          raise @error if @error

          @value
        end

        # Registers a callback to be called when the operation finishes.
        # If the operation has already finished the callback is invoked immediately
        # on the calling thread.  Otherwise it is invoked on the worker thread that
        # completes the operation.
        #
        # The callback receives +result+ and +error+ (one of them will be +nil+).
        #
        # @yield [result, error]
        # @return [self]
        # @api private
        def on_complete(&callback)
          fire_args = nil
          @mutex.synchronize do
            if @done
              fire_args = [@value, @error]
            else
              @callbacks ||= []
              @callbacks << callback
            end
          end
          callback.call(*fire_args) if fire_args
          self
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
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Rescue all Exception subclasses (not just StandardError) so that
            # non-StandardError raises such as NotImplementedError (< ScriptError)
            # still complete the operation and unblock any waiting #await callers.
            # Without this, a ScriptError in a pool worker would leave the
            # PendingOperation permanently incomplete, causing #await to deadlock.
            complete_with_error!(e)
            raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          end
        end

        private

        def complete_with_value!(value)
          cbs = nil
          @mutex.synchronize do
            @value = value
            @done = true
            @cond.broadcast
            cbs = @callbacks
            @callbacks = nil
          end
          cbs&.each { |cb| cb.call(value, nil) }
        end

        def complete_with_error!(error)
          cbs = nil
          @mutex.synchronize do
            @error = error
            @done = true
            @cond.broadcast
            cbs = @callbacks
            @callbacks = nil
          end
          cbs&.each { |cb| cb.call(nil, error) }
        end
      end

      # @param pool_size  [Integer] maximum number of worker threads
      # @param queue_size [Integer] maximum pending operations waiting for a worker
      # @param name       [String, Symbol, nil] optional pool name used in thread labels
      # @param logger     [Logger, nil] optional logger for warnings
      # @api private
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
      # @note **Cooperative callers**: if you are running under the `:fiber` backend
      #   (i.e. inside a {DeterministicScheduler} Fiber), set +timeout:+ here
      #   rather than on {PendingOperation#await}.  The await-time timeout is not
      #   enforced on the cooperative path (the Fiber cannot preempt a running
      #   worker thread).  A submit-time timeout triggers on the worker side and
      #   marks the operation {PendingOperation#abandoned? abandoned}, which
      #   unblocks the waiting Fiber via the normal on-complete callback.
      # @param timeout [Numeric, nil] seconds before the operation is abandoned
      # @param cancellation_token [CancellationToken, nil]
      # @yield block containing the blocking call
      # @return [PendingOperation]
      # @raise [Phronomy::PoolShutdownError] when the pool has been shut down
      # @raise [Phronomy::BackpressureError] when +on_full: :raise+ and queue is full
      # @raise [Phronomy::TimeoutError] when +on_full: :timeout+ and wait exceeds +full_timeout+
      # @api private
      def submit(timeout: nil, cancellation_token: nil, on_full: :wait, full_timeout: nil, &block)
        raise Phronomy::PoolShutdownError, "pool has been shut down" if @shutdown

        op = PendingOperation.new(block, timeout: timeout, cancellation_token: cancellation_token,
          on_abandoned: timeout ? -> { @mutex.synchronize { @abandoned_count += 1 } } : nil)
        begin
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
        rescue ClosedQueueError
          # Shutdown raced with this submit — treat as if @shutdown was already set.
          raise Phronomy::PoolShutdownError, "pool has been shut down"
        end
        op
      end

      # Gracefully drains the pool and terminates all worker threads.
      # Waits up to +drain_timeout+ seconds for in-flight operations to finish.
      #
      # Closing the underlying SizedQueue signals workers to exit after draining
      # remaining items, without blocking on a full-queue push.
      #
      # @param drain_timeout [Numeric] seconds to wait for workers to finish
      # @return [self]
      # @api private
      def shutdown(drain_timeout: 30)
        @shutdown = true
        @queue.close
        @workers.each { |t| t.join(drain_timeout) }
        self
      end

      # --- Metrics ----------------------------------------------------------

      # @return [Integer] number of operations currently executing on workers
      # @api private
      def active_count
        @mutex.synchronize { @active_count }
      end

      # @return [Integer] number of operations waiting in the queue
      # @api private
      def queue_depth
        @queue.size
      end

      # @return [Integer] number of operations that were abandoned due to timeout
      # @api private
      def abandoned_count
        @mutex.synchronize { @abandoned_count }
      end

      # Average time (in seconds) that completed operations spent in the queue
      # waiting for a worker.  Returns 0.0 when no operations have completed yet.
      # @return [Float]
      # @api private
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
            op = begin
              @queue.pop
            rescue ClosedQueueError
              break
            end
            # nil is returned by a closed, empty Queue on some Ruby versions
            break if op.nil? || op == SENTINEL

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
end
