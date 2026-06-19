# frozen_string_literal: true

module Phronomy
  module Concurrency
    # A thread-safe FIFO queue for passing values between concurrent tasks.
    #
    # Wraps +Thread::Queue+ so that callers do not need to reference the Ruby
    # standard-library type directly.  A future implementation may replace the
    # backing primitive without changing call sites.
    #
    # @example Producer / consumer
    #   queue = Phronomy::Concurrency::AsyncQueue.new
    #   Runtime.instance.spawn { queue.push(expensive_io()) }
    #   value = queue.pop   # blocks until the producer pushes
    # @api private
    class AsyncQueue
      # @param max_size [Integer, nil] optional upper bound on queue depth.
      #   When set, {#push} blocks the caller until a slot is available.
      # @api private
      def initialize(max_size: nil)
        @queue = max_size ? SizedQueue.new(max_size) : Thread::Queue.new
        @max_size = max_size
        @waiter_mutex = Mutex.new
        @cross_thread_waiter = nil    # [fiber, scheduler] set by _pop_cooperative; consumed by push
        @cross_thread_scheduler = nil # set by expect_cross_thread_push
      end

      # Enqueues +item+.
      # In a cooperative scheduler context with a bounded queue (max_size:), suspends
      # the current Fiber via a scheduler signal when the queue is full rather than
      # blocking the OS thread.  Without a scheduler, falls back to the standard
      # SizedQueue blocking behaviour.
      # @param item [Object] value to enqueue
      # @return [self]
      # @api private
      def push(item)
        scheduler = Phronomy::Runtime::Scheduler.current
        if scheduler && @max_size
          _push_cooperative(scheduler, item)
        else
          @queue.push(item)
          scheduler.raise_signal(@coop_signal) if scheduler && @coop_signal
          # Wake a cross-thread waiter if one is registered.
          # Handles the case where a DeterministicScheduler Fiber is suspended
          # in _pop_cooperative waiting for a push from a non-scheduler thread
          # (e.g. EventLoop thread where Scheduler.current is nil).
          # enqueue_fiber is thread-safe; complete_blocking_await decrements
          # @pending_awaits so run_until_idle can eventually exit.
          if @cross_thread_scheduler
            waiter = @waiter_mutex.synchronize do
              w = @cross_thread_waiter
              @cross_thread_waiter = nil
              w
            end
            if waiter
              fiber, sched = waiter
              sched.complete_blocking_await
              sched.enqueue_fiber(-> { fiber.resume })
            end
          end
        end
        self
      end

      # Dequeues and returns the next item.
      # In a cooperative scheduler context, suspends the current Fiber (yielding
      # control back to the scheduler) rather than blocking the OS thread.
      #
      # When +timeout+ is given the semantics depend on the active backend:
      #
      # * **Thread backend** (`:thread`) — uses real wall-clock time via
      #   +Thread::Queue#pop(timeout:)+.  Requires Ruby 3.2+.
      #   Returns +nil+ if no item arrives within the specified number of real seconds.
      # * **DeterministicScheduler / `:fiber` backend** — uses the scheduler's
      #   *virtual time* (+scheduler.virtual_time+).  The timeout elapses only when
      #   the virtual clock is advanced (e.g. via {Phronomy::Testing::FakeClock#advance}).
      #   In tests this means the timeout is fully deterministic and does not depend on
      #   actual elapsed wall time.  However, in production `:fiber` mode the timeout
      #   may never expire unless the scheduler explicitly advances virtual time.
      #
      # @note The `:fiber` backend is **EXPERIMENTAL**.  Real-time timeout behaviour
      #   in production workloads is not guaranteed and may differ from wall-clock
      #   expectations.
      # @note **Cooperative timeout limitation**: on the cooperative path, the
      #   deadline is re-checked *after* a wake-up signal arrives.  If virtual time
      #   has already passed the deadline when the consumer is woken by a producer
      #   push, the consumer returns +nil+ rather than the pushed item.  Without any
      #   wake-up signal the waiting Fiber remains suspended even after
      #   +scheduler.advance+ — the timeout does not self-fire.
      # @param timeout [Numeric, nil] seconds to wait before returning +nil+.
      #   Semantics are wall-clock on `:thread` and virtual-time on `:fiber`.
      # @return [Object, nil] the next item, or +nil+ when timeout expires
      # @api private
      def pop(timeout: nil)
        scheduler = Phronomy::Runtime::Scheduler.current
        if scheduler
          _pop_cooperative(scheduler, timeout: timeout)
        elsif timeout
          @queue.pop(timeout: timeout)
        else
          @queue.pop
        end
      end

      # Returns the current number of items in the queue.
      # @return [Integer]
      # @api private
      def size
        @queue.size
      end

      # Returns +true+ when the queue contains no items.
      # @return [Boolean]
      # @api private
      def empty?
        @queue.empty?
      end

      # Closes the queue.  Subsequent {#pop} calls raise +ClosedQueueError+.
      # @return [self]
      # @api private
      def close
        @queue.close
        self
      end

      # Marks this queue as expecting pushes from a non-scheduler OS thread.
      # When set, {#pop} in cooperative mode uses +track_blocking_await+ so that
      # {Runtime::DeterministicScheduler#run_until_idle} does not exit while
      # waiting for the cross-thread push.  Called by {EventLoop#register} when
      # a cooperative scheduler is active on the calling thread.
      # @param scheduler [Runtime::Scheduler]
      # @return [self]
      # @api private
      def expect_cross_thread_push(scheduler)
        @cross_thread_scheduler = scheduler
        self
      end

      private

      # Cooperative pop for DeterministicScheduler context.
      # Suspends the current Fiber via the scheduler's signal mechanism rather than
      # blocking the OS thread.
      #
      # Two suspension paths:
      # * **Same-scheduler** (default): uses {CoopSignal} — the producer is another
      #   Fiber on the same DeterministicScheduler.  run_until_idle is allowed to
      #   exit; the producer's push will enqueue the consumer Fiber.
      # * **Cross-thread** ({#expect_cross_thread_push} was called): uses
      #   +track_blocking_await+ so that run_until_idle does not exit while waiting
      #   for a push from a non-scheduler OS thread (e.g. EventLoop).  The push
      #   side calls +complete_blocking_await+ + +enqueue_fiber+ to resume.
      #
      # The empty?/register pair for the cross-thread path is wrapped in
      # @waiter_mutex to eliminate the race between the empty check and the
      # registration of the waker.
      # @api private
      # @param scheduler [Runtime::Scheduler]
      # @param timeout [Numeric, nil]
      # @return [Object, nil]
      def _pop_cooperative(scheduler, timeout:)
        @coop_signal ||= scheduler.new_signal
        deadline = timeout ? (scheduler.virtual_time + timeout) : nil

        loop do
          unless @queue.empty?
            item = @queue.pop(timeout: 0)
            # Notify a push-waiter (bounded queue) that a slot opened up.
            scheduler.raise_signal(@push_signal) if @push_signal
            return item
          end
          return nil if deadline && scheduler.virtual_time >= deadline

          if @cross_thread_scheduler
            # Cross-thread path: atomically check the queue and register a waker
            # so that a concurrent push cannot slip between the empty? check above
            # and the registration below.
            will_yield = false
            @waiter_mutex.synchronize do
              if @queue.empty?
                @cross_thread_waiter = [Fiber.current, scheduler]
                scheduler.track_blocking_await
                will_yield = true
              end
              # else: push arrived between the loop's empty? check and here;
              # will_yield stays false and the next loop iteration dequeues it.
            end
            Fiber.yield(:cooperative_suspend) if will_yield
          else
            scheduler.wait_for_signal(@coop_signal)
          end

          return nil if deadline && scheduler.virtual_time >= deadline
        end
      end

      # Cooperative push for DeterministicScheduler context with a bounded queue.
      # Suspends the current Fiber via a scheduler signal when the queue is full,
      # rather than blocking the OS thread.
      # @api private
      # @param scheduler [Runtime::Scheduler]
      # @param item [Object]
      # @return [void]
      def _push_cooperative(scheduler, item)
        @push_signal ||= scheduler.new_signal

        loop do
          unless @queue.size >= @max_size
            @queue.push(item)
            # Notify any pop-waiter that an item is now available.
            scheduler.raise_signal(@coop_signal) if @coop_signal
            return
          end
          scheduler.wait_for_signal(@push_signal)
        end
      end
    end
  end
end
