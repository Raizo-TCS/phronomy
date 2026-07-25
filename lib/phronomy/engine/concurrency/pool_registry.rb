# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Registry and lifecycle manager for {BlockingAdapterPool} instances.
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
      end

      # Returns (or lazily creates) the unnamed default pool.
      # @param pool_size  [Integer]
      # @param queue_size [Integer]
      # @return [BlockingAdapterPool]
      # @api private
      def default_pool(pool_size: 10, queue_size: 100)
        @default ||= BlockingAdapterPool.new(
          name: :default,
          pool_size: pool_size,
          queue_size: queue_size,
          timer_queue_provider: @timer_queue_provider
        )
      end

      # Returns (or lazily creates) a named pool.
      # @param name      [Symbol, String]
      # @param size      [Integer]
      # @param queue_size [Integer]
      # @return [BlockingAdapterPool]
      # @api private
      def named_pool(name, size: 10, queue_size: 100)
        @mutex.synchronize do
          @pools[name.to_sym] ||= BlockingAdapterPool.new(
            name: name,
            pool_size: size,
            queue_size: queue_size,
            timer_queue_provider: @timer_queue_provider
          )
        end
      end

      # Shuts down the default pool and all named pools.
      # @return [void]
      # @api private
      def shutdown
        @default&.shutdown
        pools = @mutex.synchronize { @pools.values.dup }
        pools.each(&:shutdown)
      end
    end
  end
end
