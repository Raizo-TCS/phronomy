# frozen_string_literal: true

module Phronomy
  module Concurrency
    # A bounded, observable thread pool for synchronous work that must not run on
    # the Runtime EventLoop.
    #
    # ## Architectural boundary
    #
    # `OffloadPool` is the bounded OS-thread execution boundary for synchronous
    # operations that would otherwise occupy the EventLoop for too long. The work
    # may be blocking I/O, CPU-bound Ruby processing, or another application-defined
    # synchronous call. Phronomy deliberately does not classify the workload by
    # cause; the application decides whether a unit of work is EventLoop-safe.
    #
    # Logical waits are different. Waiting for another Phronomy Task, Agent,
    # Workflow, ToolInvocation, timer, or FSMSession must remain an explicit
    # EventLoop/FSMSession continuation and must not consume an OffloadPool worker.
    # See ADR-010.
    #
    # Submitted work is bounded so that:
    #
    # 1. The total number of worker OS threads is capped.
    # 2. Queue depth is bounded (backpressure when the pool is saturated).
    # 3. Per-operation timeouts and cancellation settle the caller-facing handle.
    # 4. Operations that settle after worker execution has started are tracked as
    #    abandoned until that worker returns.
    # 5. Metrics expose active work, queue depth, cumulative abandonment,
    #    currently-active abandonment, and average queue wait time.
    #
    # OffloadPool does not provide CPU isolation, CPU parallelism guarantees, or
    # fairness between I/O and CPU-heavy work classes. Applications that need
    # resource isolation may use named pools via {Runtime#pool}.
    #
    # @example Submitting synchronous work
    #   op = runtime.offload.submit(timeout: 30) { expensive_call }
    #   result = op.blocking_wait   # blocks the calling thread until done
    #
    # @example With cancellation
    #   token = Phronomy::Concurrency::CancellationToken.timeout_after(60)
    #   op = pool.submit(timeout: 30, cancellation_token: token) { expensive_call }
    #   result = op.blocking_wait
    class OffloadPool
      # Represents the pending result of submitted offloaded work.
      # Returned immediately by {OffloadPool#submit}; call {#blocking_wait}
      # to synchronously wait from a non-EventLoop caller such as a low-level test.
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

        # @return [Boolean] true when submit cancellation settled the operation
        # @api private
        def cancelled?
          @mutex.synchronize { @cancelled }
        end

        # @return [Boolean] true when timeout/cancellation settled the caller-facing
        #   operation after worker execution had started. The worker is not forcibly
        #   interrupted and its eventual result is discarded.
        # @api private
        def abandoned?
          @mutex.synchronize { @abandoned }
        end

        # @return [Float] seconds spent in the queue before execution started
        # @api private
        def wait_time
          @wait_time || 0.0
        end

        # Blocks the calling thread until the operation settles and returns its value.
        #
        # A +timeout+ passed here is local to this synchronous waiter. When it expires,
        # {Phronomy::TimeoutError} is raised to this caller, but the operation is not
        # settled, marked abandoned, or otherwise changed. The worker continues, and
        # another waiter or an +on_complete+ callback may receive the eventual result
        # unless the submit-time deadline or submit cancellation settles the operation
        # first.
        #
        # Operation-wide cancellation belongs exclusively to the
        # +cancellation_token:+ passed to {OffloadPool#submit}. PendingOperation does
        # not define a separate waiter-local cancellation-token lifecycle.
        #
        # @param timeout [Numeric, nil] maximum seconds this waiter will block
        # @return [Object]
        # @raise [Phronomy::TimeoutError]
        # @raise [Exception] error that settled the submitted operation
        # @api private
        def blocking_wait(timeout: nil)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
          value, error = @mutex.synchronize do
            until @done
              if deadline
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if remaining <= 0
                  raise Phronomy::TimeoutError,
                    "timed out waiting for offloaded operation after #{timeout}s"
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

        # Registers an independent callback to be called when the operation settles.
        #
        # If the operation has already settled, the callback is invoked immediately
        # on the calling thread. Otherwise it may be invoked on a pool worker thread,
        # on the EventLoop thread when a timer fires, or on the thread that explicitly
        # cancels the submit cancellation token. The execution thread is not
        # guaranteed; callbacks must be thread-safe and should complete quickly.
        #
        # Completion callback failures are logged and isolated. One callback cannot
        # suppress delivery to later callbacks or change the operation's settled
        # result.
        #
        # The callback receives +result+ and +error+ (one of them will be +nil+).
        #
        # @yield [result, error]
        # @return [self]
        # @api private
        def on_complete(&callback)
          raise ArgumentError, "on_complete requires a block" unless callback

          fire_args = nil
          @mutex.synchronize do
            if @done
              fire_args = [@value, @error]
            else
              @callbacks ||= []
              @callbacks << callback
            end
          end
          deliver_completion_callback(callback, *fire_args) if fire_args
          self
        end

        # @api private
        def initialize(
          block,
          timeout: nil,
          cancellation_token: nil,
          on_abandoned: nil,
          submitted_at: nil
        )
          @block = block
          @timeout = timeout
          @cancellation_token = cancellation_token
          @on_abandoned = on_abandoned
          @value = nil
          @error = nil
          @done = false
          @timed_out = false
          @cancelled = false
          @started = false
          @abandoned = false
          @wait_time = nil
          @submitted_at = submitted_at ||
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @mutex = Mutex.new
          @cond = ConditionVariable.new

          # Explicit submit cancellation is operation-wide. Deadline-only tokens are
          # promoted to cancel! by OffloadPool#submit using the Runtime timer queue.
          @cancellation_callback = if @cancellation_token
            -> { fire_cancellation! }
          end
          @cancellation_token&.on_cancel(&@cancellation_callback)
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
          settle_early!(timed_out: true) do
            Phronomy::TimeoutError.new(
              "offloaded operation timed out after #{@timeout}s"
            )
          end
        end

        # Settles the operation because its submit cancellation token was cancelled.
        #
        # Cancellation is caller-facing settlement, not asynchronous worker
        # interruption. If execution has already started, the operation is marked
        # abandoned and the worker continues until the synchronous call returns.
        #
        # @return [Boolean] true when this call settled the operation
        # @api private
        def fire_cancellation!
          settle_early!(cancelled: true) do |started|
            message = if started
              "offloaded operation cancelled during execution"
            else
              "offloaded operation cancelled before execution"
            end
            CancellationError.new(message)
          end
        end

        # Marks an operation that could not be admitted to the pool as settled, so a
        # previously armed submit-time timer becomes a harmless no-op.
        #
        # @param error [Exception, nil]
        # @return [Boolean] true when this call changed the state
        # @api private
        def fail_submission!(error = nil)
          callbacks = nil
          changed = @mutex.synchronize do
            next false if @done

            @done = true
            @error = error if error
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
            true
          end

          detach_submit_cancellation if changed
          deliver_completion_callbacks(callbacks, nil, error) if changed
          changed
        end

        # Executes the operation on a pool worker.
        # @api private
        def execute!
          @wait_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @submitted_at

          # A monotonic deadline can make cancelled? true before the timer callback
          # runs. Promote that state to explicit cancellation so callbacks and all
          # observers see the same operation-wide settlement.
          if @cancellation_token&.cancelled?
            @cancellation_token.cancel!
          end

          should_run = @mutex.synchronize do
            if @done
              false
            else
              # Linearization point: after this assignment, a concurrent timeout or
              # cancellation is classified as in-flight abandonment and the block
              # itself is allowed to finish without Thread#raise.
              @started = true
              true
            end
          end
          return unless should_run

          # Do NOT use Timeout.timeout here — it delivers an async Thread#raise
          # that can corrupt library/application state (mutexes, C extensions, etc.).
          # I/O libraries should set native connection/read timeouts. CPU-heavy work
          # that needs hard termination should use a future process-offload facility.
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

        def settle_early!(timed_out: false, cancelled: false)
          callbacks = nil
          abandoned_now = false
          error = nil

          changed = @mutex.synchronize do
            next false if @done

            # The error and @started classification are decided under the same lock
            # as settlement. This is the cancellation/worker-start linearization
            # point: cancellation that wins here prevents execution; worker start
            # that wins first produces an abandoned in-flight operation.
            error = yield(@started)
            @done = true
            @timed_out = timed_out
            @cancelled = cancelled
            @error = error
            @abandoned = @started
            abandoned_now = @abandoned
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
            true
          end
          return false unless changed

          detach_submit_cancellation
          notify_abandoned if abandoned_now
          deliver_completion_callbacks(callbacks, nil, error)
          true
        end

        def notify_abandoned
          @on_abandoned&.call(self)
        rescue => error
          Phronomy.configuration.logger&.error do
            "OffloadPool abandoned callback failed: #{error.class}: #{error.message}"
          end
        end

        def complete_with_value!(value)
          callbacks = nil
          changed = @mutex.synchronize do
            next false if @done

            @value = value
            @done = true
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
            true
          end
          detach_submit_cancellation if changed
          deliver_completion_callbacks(callbacks, value, nil) if changed
          changed
        end

        def complete_with_error!(error)
          callbacks = nil
          changed = @mutex.synchronize do
            next false if @done

            @error = error
            @done = true
            @cond.broadcast
            callbacks = @callbacks
            @callbacks = nil
            true
          end
          detach_submit_cancellation if changed
          deliver_completion_callbacks(callbacks, nil, error) if changed
          changed
        end

        def deliver_completion_callbacks(callbacks, value, error)
          callbacks&.each do |callback|
            deliver_completion_callback(callback, value, error)
          end
        end

        def deliver_completion_callback(callback, value, error)
          callback.call(value, error)
        rescue => callback_error
          Phronomy.configuration.logger&.error do
            "[OffloadPool::PendingOperation] on_complete callback raised " \
              "#{callback_error.class}: #{callback_error.message}"
          end
        end

        def detach_submit_cancellation
          return unless @cancellation_token && @cancellation_callback

          @cancellation_token.send(
            :unregister_cancel_callback,
            @cancellation_callback
          )
          @cancellation_callback = nil
        end
      end

      # @param pool_size  [Integer] maximum number of worker threads
      # @param queue_size [Integer] maximum pending operations waiting for a worker
      # @param name       [String, Symbol, nil] optional pool name used in thread labels
      # @param logger     [Logger, nil] optional logger for warnings
      # @param timer_queue_provider [#call, nil] returns a TimerQueue-compatible
      #   object. Required when +submit(timeout:)+ or a monotonic-deadline
      #   cancellation token is used.
      # @api private
      def initialize(
        pool_size: 10,
        queue_size: 100,
        name: nil,
        logger: nil,
        timer_queue_provider: nil
      )
        @pool_size = pool_size
        @queue_size = queue_size
        @name = name
        @logger = logger
        @timer_queue_provider = timer_queue_provider
        @queue = SizedQueue.new(queue_size)
        @active_count = 0
        @abandoned_count = 0
        @running_operation_ids = {}
        @abandoned_active_operation_ids = {}
        @total_wait_ns = 0
        @completed_count = 0
        @mutex = Mutex.new
        @shutdown = false
        @workers = Array.new(pool_size) { |i| spawn_worker(i) }
      end

      # Submits synchronous off-EventLoop work to the pool.
      # Returns a {PendingOperation} immediately after queue admission; the block runs
      # on a worker thread. Do not submit logical waits (for example waiting for a
      # child Agent Task) merely to make them asynchronous; those belong to
      # FSMSession/EventLoop completion events.
      #
      # A submit-time +timeout+ is an operation-wide deadline measured from the start
      # of this method, including queue wait. The timer settles the PendingOperation
      # and notifies +on_complete+ without forcibly interrupting a running worker.
      # If the deadline fires before worker execution starts, the block is skipped.
      # If it fires after execution starts, the operation is marked abandoned and the
      # eventual worker result is discarded.
      #
      # The submit +cancellation_token+ is also operation-wide. Explicit cancellation
      # settles the PendingOperation immediately. A token with a monotonic deadline is
      # attached to the Runtime timer queue so deadline expiry becomes explicit
      # cancellation without adding a polling Thread. Cancellation before execution
      # skips the block; cancellation after execution starts abandons only the
      # caller-facing result and never uses Thread#raise.
      #
      # Synchronous queue admission may delay return from this method when
      # +on_full: :wait+ is used. EventLoop-owned framework paths therefore submit
      # with +on_full: :raise+ and handle backpressure asynchronously.
      #
      # @param timeout [Numeric, nil] operation-wide deadline in seconds
      # @param cancellation_token [CancellationToken, nil] operation-wide token
      # @param on_full [Symbol] +:wait+, +:raise+, or +:timeout+
      # @param full_timeout [Numeric, nil] queue-admission timeout for +on_full: :timeout+
      # @yield block containing synchronous work
      # @return [PendingOperation]
      # @raise [Phronomy::ConfigurationError] when a timer is required but no
      #   timer queue provider is configured
      # @raise [Phronomy::PoolShutdownError] when the pool has been shut down
      # @raise [Phronomy::BackpressureError] when +on_full: :raise+ and queue is full
      # @raise [Phronomy::TimeoutError] when +on_full: :timeout+ exceeds +full_timeout+
      # @api private
      def submit(
        timeout: nil,
        cancellation_token: nil,
        on_full: :wait,
        full_timeout: nil,
        &block
      )
        raise Phronomy::PoolShutdownError, "pool has been shut down" if @shutdown

        submitted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        already_cancelled = cancellation_token&.cancelled? || false
        cancellation_remaining = if already_cancelled
          nil
        else
          cancellation_token&.remaining_monotonic_seconds
        end

        needs_timer = !timeout.nil? ||
          (!cancellation_remaining.nil? && cancellation_remaining > 0)
        timer_queue = @timer_queue_provider&.call if needs_timer
        if needs_timer && !timer_queue
          raise Phronomy::ConfigurationError,
            "timer_queue is required when submit timeout or cancellation deadline is specified"
        end

        op = PendingOperation.new(
          block,
          timeout: timeout,
          cancellation_token: cancellation_token,
          submitted_at: submitted_at,
          on_abandoned: method(:record_abandoned)
        )

        # on_cancel only reacts to explicit cancel!, whereas cancelled? also covers a
        # monotonic deadline. Promote an already-expired deadline immediately.
        if already_cancelled
          cancellation_token.cancel!
          return op
        end

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

          if cancellation_remaining
            # Re-read after timeout setup so the scheduled delay reflects setup time.
            remaining = cancellation_token.remaining_monotonic_seconds
            if remaining <= 0
              cancellation_token.cancel!
              return op
            end
            timer_queue.schedule(seconds: remaining) { cancellation_token.cancel! }
          end

          # Cancellation/timeout can race with timer registration. Do not enqueue
          # already-settled work when the race is observable here.
          return op if op.done?

          case on_full
          when :raise
            begin
              @queue.push(op, true)
            rescue ThreadError
              raise Phronomy::BackpressureError,
                "OffloadPool queue is full (depth: #{@queue_size})"
            end
          when :timeout
            deadline = full_timeout ?
              (Process.clock_gettime(Process::CLOCK_MONOTONIC) + full_timeout) :
              nil
            loop do
              return op if op.done?

              @queue.push(op, true)
              break
            rescue ThreadError
              if deadline &&
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                raise Phronomy::TimeoutError,
                  "timed out waiting for a free slot in OffloadPool"
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

      # @return [Integer] cumulative number of operations whose caller-facing timeout
      #   or cancellation settled after worker execution had started
      # @api private
      def abandoned_count
        @mutex.synchronize { @abandoned_count }
      end

      # @return [Integer] number of abandoned operations that still occupy worker
      #   capacity at this instant
      # @api private
      def abandoned_active_count
        @mutex.synchronize { @abandoned_active_operation_ids.size }
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
        label = ["phronomy", "offload-pool", @name, index].compact.join("-")
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

      def record_abandoned(operation)
        operation_id = operation.object_id
        @mutex.synchronize do
          @abandoned_count += 1
          if @running_operation_ids.key?(operation_id)
            @abandoned_active_operation_ids[operation_id] = true
          end
        end
      end

      def run_operation(op)
        operation_id = op.object_id
        @mutex.synchronize do
          @active_count += 1
          @running_operation_ids[operation_id] = true
        end

        begin
          op.execute!
        ensure
          abandoned = op.abandoned?
          wait_ns = (op.wait_time * 1_000_000_000).to_i

          @mutex.synchronize do
            @active_count -= 1
            @running_operation_ids.delete(operation_id)
            @abandoned_active_operation_ids.delete(operation_id)
            @total_wait_ns += wait_ns
            @completed_count += 1
          end

          if abandoned
            @logger&.warn do
              "OffloadPool: worker finished after caller-facing timeout/cancellation settlement"
            end
          end
        end
      end
    end
  end
end
