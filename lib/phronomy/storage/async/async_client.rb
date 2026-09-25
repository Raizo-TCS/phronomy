# frozen_string_literal: true

module Phronomy
  module Storage
    # Asynchronous execution of a synchronous raw storage backend.
    #
    # A transaction opens, runs and closes on one worker. Return values rather
    # than transaction views: a bound view is closed when the block finishes.
    # Timeout includes queue wait. Timeout/cancellation settles TaskResult but
    # does not interrupt running I/O or guarantee rollback of a started write.
    # Construction starts no Runtime; the default pool is resolved per operation.
    # An explicitly injected pool remains owned by its caller.
    #
    # @api public
    class AsyncClient
      # @param backend [Storage::Backend] synchronous raw SPI 2 backend
      # @param pool [Concurrency::OffloadPool, nil] optional execution pool
      # @api public
      def initialize(backend:, pool: nil)
        Backend.validate_capabilities!(backend)
        @backend = backend
        @pool = pool
      end

      # Executes the entire transaction on one worker without waiting for queue
      # capacity. Explicit nested backend transactions retain savepoint semantics.
      #
      # @param cancellation_token [Concurrency::CancellationToken, nil]
      # @param timeout [Numeric, nil] operation-wide submit timeout
      # @yieldparam view [Storage::View] view valid only within this transaction
      # @return [Phronomy::TaskResult] the pool's original completion handle
      # @api public
      def transaction_async(cancellation_token: nil, timeout: nil, &operation)
        raise ArgumentError, "transaction_async requires a block" unless operation

        default_pool.submit(timeout: timeout, cancellation_token: cancellation_token, on_full: :raise) do
          @backend.transaction(&operation)
        end
      end

      # Submit an existing domain-owned synchronous storage unit unchanged.
      # It may already open transactions or perform reads/reconciliation. Do not
      # add a transaction, timeout or cancellation condition around that unit.
      # The owner supplies its current runtime's pool and applies the result.
      #
      # @api private
      def self.submit(pool:, &operation)
        raise ArgumentError, "storage submit requires a block" unless operation

        pool.submit(on_full: :raise, &operation)
      end

      private

      def default_pool
        @pool || Phronomy::Runtime.instance.offload
      end
    end
  end
end
