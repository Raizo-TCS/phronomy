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
    # current concurrency requirements together with EventLoop/FSMSession. (See ADR-010.)
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
    #   result = op.blocking_wait   # blocks the calling thread until done
    #
    # @example With cancellation
    #   token = Phronomy::Concurrency::CancellationToken.timeout_after(60)
    #   op = pool.submit(timeout: 30, cancellation_token: token) { expensive_call }
    #   result = op.blocking_wait
    class BlockingAdapterPool
      # Represents the pending result of a submitted blocking operation.
      # Returned immediately by {BlockingAdapterPool#submit}; call {#blocking_wait}
      # to wait for the result.
      class PendingOperation
        # @return [Boolean] true when the caller-facing result has settled
        #   (success, failure, cancellation, or submit-time timeout)
        # @api private
        def done?
          @mutex.synchronize { @done }
        end

        # @return [Boolean] true when the submit-time deadline settled the operation
        # @api private
        def timed_out?
          @mutex.synchronize { @timed_out }
        end

        # @return [Boolean] true when a submit-time timeout occurred after worker
        #   execution had started. The worker is not forcibly interrupted.
        # @api private
        def abandoned?
          @mutex.synchronize { @abandoned }
        end

        # @return [Float] seconds spent in the queue before execution started
        # @api private
        def wait_time
          @wait_time || 0.0
        end

        # Blocks until the operation completes and returns its value.
        #
        # A +timeout+ passed here is local to this waiter. When it expires,
        # {Phronomy::TimeoutError} is raised to this caller, but the operation is not
        # settled, marked abandoned, or otherwise changed. The worker continues, and
        # another waiter or an +on_complete+ callback may receive the eventual result
        # unless the submit-time deadline or cancellation settles the operation first.
        #
        # A submit-time timeout passed to {BlockingAdapterPool#submit} is enforced by
        # the runtime timer queue independently of this method and is therefore not
        # re-read here.
        #
        # An optional +cancellation_token+ may be passed here (or at submit time).
        # If the token is cancelled while waiting, {Phronomy::CancellationError} is
        # raised without interrupting the worker.
        #
        # @param timeout [Numeric, nil] maximum seconds this waiter will block
        # @param cancellation_token [CancellationToken, nil]
        # @return [Object]
        # @raise [Phronomy::TimeoutError]
        # @raise [Phronomy::CancellationError]
        # @raise [Exception] error raised inside the submitted block
        # @api private
        def blocking_wait(timeout: nil, cancellation_token: nil)
          effective_token = cancellation_token || @cancellation_token

          raise CancellationError, "blocking operation cancelled" if effective_token&.cancelled?

          # Wake up the waiting thread whenever the token is cancelled so we can
          # propagate cancellation without sleeping until the operation completes.
          effective_token&.on_cancel { @mutex.synchronize { @cond.broadcast } }

          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
          value, error = @mutex.synchronize do
            until @done
              raise CancellationError, "blocking operation cancelled" if effective_token&.cancelled?

              if deadline
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if remaining <= 0
                  raise Phronomy::TimeoutError, "timed out waiting for blocking operation after #{timeout}s"
                end
                @cond.wait(@mutex, remaining)
              else
                @cond.wait(@mutex)
              end
            end

            [@value, @error]
          end

          raise error if error

          value
        end

        # Unified wait interface compatible with {Phronomy::Task#wait_result}.
        alias_method :wait_result, :blocking_wait

        # Registers a callback to be called when the operation settles.
        #
        # If the operation has already settled, the callback is invoked immediately
        # on the calling thread. Otherwise it may be invoked on a pool worker thread
        # or on the EventLoop thread when an operation timeout fires. The execution
        # thread is not guaranteed;
        # callbacks must be thread-safe and should complete quickly.
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
        def initialize(block, timeout: nil, cancellation_token: nil, on_abandoned: nil, submitted_at: nil)
          @block = block
          @timeout = timeout
          @cancellation_token = cancellation_token
          @on_abandoned = on_abandoned
          @value = nil
          @error = nil
          @done = false
          @timed_out = false
          @started = false
          @abandoned = false
          @wait_time = nil
          @submitted_at = submitted_at || Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @mutex = Mutex.new
          @cond = ConditionVariable.new
        end

        # Settles the operation with a submit-time timeout.
        #
        # The worker is not interrupted. If execution has already started, the
        # operation is marked abandoned and the worker's eventual result is discarded.
        #
        # @return [Boolean] true when this call settled the operation, false when the
        #   operation had already settled
        # @api private
        def fire_timeout!
          error = Phronomy::TimeoutError.new(
            "blocking operation timed out after #{@timeout}s"
          )
          callbacks = nil
          abandoned_now = false

          @mutex.synchronize do
            return false if @done

            @done = true
            @timed_out = true
            @error = error
            @abandoned = @started
            abandoned_now = @abandoned
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
          end

          # Internal bookkeeping is completed before user callbacks run. A metrics
          # callback must never suppress delivery of TimeoutError to on_complete.
          if abandoned_now
            begin
              @on_abandoned&.call
            rescue => e
              Phronomy.configuration.logger&.error {
                "BlockingAdapterPool abandoned callback failed: #{e.class}: #{e.message}"
              }
            end
          end

          callbacks&.each { |callback| callback.call(nil, error) }
          true
        end

        # Marks an operation that could not be admitted to the pool as settled, so a
        # previously armed submit-time timer becomes a harmless no-op.
        #
        # @param error [Exception, nil]
        # @return [Boolean] true when this call changed the state
        # @api private
        def fail_submission!(error = nil)
          @mutex.synchronize do
            return false if @done

            @done = true
            @error = error if error
            @cond.broadcast
          end
          true
        end

        # Executes the operation on a pool worker.
        # @api private
        def execute!
          @wait_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @submitted_at

          cancellation_error = nil
          callbacks = nil
          should_run = @mutex.synchronize do
            if @done
              false
            elsif @cancellation_token&.cancelled?
              cancellation_error = CancellationError.new("operation cancelled before execution")
              @done = true
              @error = cancellation_error
              @cond.broadcast
              callbacks = @callbacks
              @callbacks = nil
              false
            else
              # Linearization point: after this assignment, a concurrent timeout is
              # classified as an in-flight abandonment and the block will run.
              @started = true
              true
            end
          end

          if cancellation_error
            callbacks&.each { |callback| callback.call(nil, cancellation_error) }
            return
          end

          return unless should_run

          # Do NOT use Timeout.timeout here — it delivers an async Thread#raise
          # that can corrupt external library state (mutexes, C extensions, etc.).
          # Each blocking library should set its own native connection/read timeout.
          begin
            complete_with_value!(@block.call)
          rescue Exception => e # rubocop:disable Lint/RescueException
            # Rescue all Exception subclasses so non-StandardError raises still
            # settle the operation and unblock waiters.
            complete_with_error!(e)
            raise if e.is_a?(SignalException) || e.is_a?(SystemExit)
          end
        end

        private

        def complete_with_value!(value)
          callbacks = nil
          @mutex.synchronize do
            return false if @done

            @value = value
            @done = true
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
          end
          callbacks&.each { |callback| callback.call(value, nil) }
          true
        end

        def complete_with_error!(error)
          callbacks = nil
          @mutex.synchronize do
            return false if @done

            @error = error
            @done = true
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
          end
          callbacks&.each { |callback| callback.call(nil, error) }
          true
        end
      end

      # @param pool_size  [Integer] maximum number of worker threads
      # @param queue_size [Integer] maximum pending operations waiting for a worker
      # @param name       [String, Symbol, nil] optional pool name used in thread labels
      # @param logger     [Logger, nil] optional logger for warnings
      # @param timer_queue_provider [#call, nil] returns a TimerQueue-compatible
      #   object. Required when +submit(timeout:)+ is used.
      # @api private
      def initialize(pool_size: 10, queue_size: 100, name: nil, logger: nil, timer_queue_provider: nil)
        @pool_size = pool_size
        @queue_size = queue_size
        @name = name
        @logger = logger
        @timer_queue_provider = timer_queue_provider
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
      # Returns a {PendingOperation} immediately after queue admission; the block runs
      # on a worker thread.
      #
      # A submit-time +timeout+ is an operation-wide deadline measured from the start
      # of this method, including queue wait. The timer settles the PendingOperation
      # and notifies +on_complete+ without forcibly interrupting a running worker.
      # If the deadline fires before worker execution starts, the block is skipped and
      # the operation is not counted as abandoned. If it fires after execution starts,
      # the operation is marked abandoned and the eventual worker result is discarded.
      #
      # Synchronous queue admission may still delay return from this method when
      # +on_full: :wait+ is used; resolving that requires interruptible admission.
      #
      # @param timeout [Numeric, nil] operation-wide deadline in seconds
      # @param cancellation_token [CancellationToken, nil]
      # @param on_full [Symbol] +:wait+, +:raise+, or +:timeout+
      # @param full_timeout [Numeric, nil] queue-admission timeout for +on_full: :timeout+
      # @yield block containing the blocking call
      # @return [PendingOperation]
      # @raise [Phronomy::ConfigurationError] when +timeout+ is specified without a
      #   timer queue provider
      # @raise [Phronomy::PoolShutdownError] when the pool has been shut down
      # @raise [Phronomy::BackpressureError] when +on_full: :raise+ and queue is full
      # @raise [Phronomy::TimeoutError] when +on_full: :timeout+ exceeds +full_timeout+
      # @api private
      def submit(timeout: nil, cancellation_token: nil, on_full: :wait, full_timeout: nil, &block)
        raise Phronomy::PoolShutdownError, "pool has been shut down" if @shutdown

        submitted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        timer_queue = nil
        if timeout
          timer_queue = @timer_queue_provider&.call
          unless timer_queue
            raise Phronomy::ConfigurationError,
              "timer_queue is required when submit timeout is specified"
          end
        end

        op = PendingOperation.new(
          block,
          timeout: timeout,
          cancellation_token: cancellation_token,
          submitted_at: submitted_at,
          on_abandoned: timeout ? -> { @mutex.synchronize { @abandoned_count += 1 } } : nil
        )

        begin
          if timeout
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - submitted_at
            remaining = timeout.to_f - elapsed
            if remaining <= 0
              op.fire_timeout!
              return op
            end

            # Arm before queue admission so the deadline includes time spent waiting
            # for a queue slot.
            timer_queue.schedule(seconds: remaining) { op.fire_timeout! }
          end

          case on_full
          when :raise
            begin
              @queue.push(op, true)
            rescue ThreadError
              raise Phronomy::BackpressureError,
                "BlockingAdapterPool queue is full (depth: #{@queue_size})"
            end
          when :timeout
            deadline = full_timeout ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) + full_timeout) : nil
            loop do
              @queue.push(op, true)
              break
            rescue ThreadError
              if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                raise Phronomy::TimeoutError,
                  "timed out waiting for a free slot in BlockingAdapterPool"
              end
              sleep(0.005)
            end
          else # :wait (default)
            @queue.push(op)
          end
        rescue ClosedQueueError => e
          # Shutdown raced with this submit — preserve the existing public error.
          op.fail_submission!(e)
          raise Phronomy::PoolShutdownError, "pool has been shut down"
        rescue => e
          op.fail_submission!(e)
          raise
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
        @workers.each { |thread| thread.join(drain_timeout) }
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

      # @return [Integer] number of operations whose caller-facing timeout fired
      #   after worker execution had started
      # @api private
      def abandoned_count
        @mutex.synchronize { @abandoned_count }
      end

      # Average time (in seconds) that completed or skipped operations spent in the
      # queue waiting for a worker. Returns 0.0 when none have been processed yet.
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
