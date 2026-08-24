# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Private Task specialization used when logical completion and physical
    # completion are intentionally different boundaries.
    #
    # Offload cancellation/timeout may settle the caller-facing Task while a
    # worker is still executing. EventLoop supervision must observe the later
    # physical-completion boundary without adding domain-specific state to the
    # public Phronomy::Task contract.
    #
    # @api private
    class PhysicalCompletionTask < Phronomy::Task
      # @api private
      def initialize(name: nil, parent: nil)
        super
        @physical_mutex = Mutex.new
        @physical_complete = false
        @physical_callbacks = []
      end

      # @return [Boolean]
      # @api private
      def physical_complete?
        @physical_mutex.synchronize { @physical_complete }
      end

      # Registers a callback that fires only when the underlying physical work
      # can no longer affect the owning execution.
      #
      # @return [self]
      # @api private
      def on_physical_complete(&callback)
        raise ArgumentError, "on_physical_complete requires a block" unless callback

        fire_now = @physical_mutex.synchronize do
          if @physical_complete
            true
          else
            @physical_callbacks << callback
            false
          end
        end
        deliver_physical_callback(callback) if fire_now
        self
      end

      # Idempotently marks the physical work boundary complete.
      #
      # @return [self]
      # @api private
      def mark_physical_complete!
        callbacks = @physical_mutex.synchronize do
          return self if @physical_complete

          @physical_complete = true
          current = @physical_callbacks
          @physical_callbacks = []
          current
        end
        callbacks.each { |callback| deliver_physical_callback(callback) }
        self
      end

      # Preserves the physical-completion boundary across Task#map.
      #
      # A mapped PhysicalCompletionTask is physically complete only after both:
      # 1. the source Task's underlying physical work is complete; and
      # 2. the mapping callback itself has finished running.
      #
      # The second condition is required because Task completion callbacks may run
      # on the OffloadPool worker that settles the source Task. Propagating the
      # source physical signal immediately could otherwise let EventLoop declare
      # the owning Execution quiescent while the mapping callback is still active.
      #
      # Logical success/failure semantics intentionally remain the same as
      # Phronomy::Task#map.
      #
      # @api public
      def map(&block)
        raise ArgumentError, "map requires a block" unless block

        mapped = self.class.deferred(name: "#{name}-mapped", parent: parent)
        propagation_mutex = Mutex.new
        source_physical_complete = physical_complete?
        mapping_complete = false

        mark_mapped_physical_if_ready = lambda do
          ready = propagation_mutex.synchronize do
            source_physical_complete && mapping_complete
          end
          mapped.mark_physical_complete! if ready
        end

        on_physical_complete do
          propagation_mutex.synchronize { source_physical_complete = true }
          mark_mapped_physical_if_ready.call
        end

        on_complete do |value, error|
          if error
            propagation_mutex.synchronize { mapping_complete = true }
            mark_mapped_physical_if_ready.call
            mapped.fail(error)
            next
          end

          begin
            transformed = block.call(value)
            propagation_mutex.synchronize { mapping_complete = true }
            mark_mapped_physical_if_ready.call
            mapped.complete(transformed)
          rescue => mapped_error
            propagation_mutex.synchronize { mapping_complete = true }
            mark_mapped_physical_if_ready.call
            mapped.fail(mapped_error)
          end
        end

        mapped
      end

      private

      def deliver_physical_callback(callback)
        callback.call
      rescue => error
        Phronomy.configuration.logger&.error do
          "[PhysicalCompletionTask] callback raised #{error.class}: #{error.message}"
        end
      end
    end
  end
end
