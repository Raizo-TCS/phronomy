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
