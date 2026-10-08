# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Registry and lifecycle manager for {OffloadPool} instances.
    #
    # Maintains one unnamed "default" pool (accessed via {#default_pool}) and
    # an arbitrary number of named pools (accessed via {#named_pool}).
    # All pools are shut down together by {#shutdown}.
    # @api private
    class PoolRegistry
      # @param timer_queue_provider [#call, nil] provider passed to every pool
      # @api private
      def initialize(timer_queue_provider: nil)
        @timer_queue_provider = timer_queue_provider
        @mutex = Mutex.new
        @pools = {}
        @default = nil
        @closed = false
      end

      # Returns (or lazily creates) the unnamed default pool.
      # @param pool_size  [Integer]
      # @param queue_size [Integer]
      # @return [OffloadPool]
      # @api private
      def default_pool(pool_size: 10, queue_size: 100)
        @mutex.synchronize do
          ensure_open!
          @default ||= OffloadPool.new(
            name: :default,
            pool_size: pool_size,
            queue_size: queue_size,
            timer_queue_provider: @timer_queue_provider
          )
        end
      end

      # Lookup only, including after registration has closed.
      # @return [OffloadPool, nil]
      # @api private
      def default_pool_if_initialized
        @mutex.synchronize { @default }
      end

      # Returns (or lazily creates) a named pool.
      # @param name      [Symbol, String]
      # @param size      [Integer]
      # @param queue_size [Integer]
      # @return [OffloadPool]
      # @api private
      def named_pool(name, size: 10, queue_size: 100)
        @mutex.synchronize do
          ensure_open!
          @pools[name.to_sym] ||= OffloadPool.new(
            name: name,
            pool_size: size,
            queue_size: queue_size,
            timer_queue_provider: @timer_queue_provider
          )
        end
      end

      # Closes registration and every pool before waiting, outside the registry
      # lock. All pools share one absolute monotonic deadline. Attempt every
      # cleanup even if one fails; report physical completion separately.
      # @return [Boolean] whether every owned worker has stopped
      # @api private
      def shutdown(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30)
        pools = @mutex.synchronize do
          @closed = true
          [@default, *@pools.values].compact
        end
        error = nil
        pools.each do |pool|
          pool.begin_shutdown
        rescue => caught
          error ||= caught
        end
        pools.each do |pool|
          pool.shutdown(deadline: deadline)
        rescue => caught
          error ||= caught
        end
        raise error if error

        pools.all?(&:terminated?)
      end

      private

      def ensure_open!
        raise Phronomy::PoolShutdownError, "pool registry has been shut down" if @closed
      end
    end
  end
end
