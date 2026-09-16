# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Runtime-local admission for one synchronous coordination call per owner
    # (a Handoff main Agent or TeamCoordinator). This does not own durable runs
    # or active-agent mutation; those remain in their existing domains.
    # @api private
    class AdmissionRegistry
      # Construction has no side effects. Runtime returns the registered instance
      # when callers concurrently supply candidates for the same key.
      # @api private
      def self.for(runtime)
        runtime.__register_shutdown_participant(key: self, participant: new)
      end

      def initialize
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @owners = {}
        @draining = false
      end

      def admit!(coordinator)
        key = coordinator.object_id
        @mutex.synchronize do
          if @draining
            raise Phronomy::RuntimeShutdownError,
              "Runtime is shutting down or failed; new Multi-Agent turns are not accepted"
          end
          if @owners.key?(key)
            raise Phronomy::HandoffError,
              "a Multi-Agent turn is already active for this main Agent instance"
          end
          @owners[key] = coordinator
        end
        true
      end

      def release!(coordinator)
        key = coordinator.object_id
        @mutex.synchronize do
          removed = @owners.delete(key)
          @cond.broadcast if @owners.empty?
          !removed.nil?
        end
      end

      def idle?
        @mutex.synchronize { @owners.empty? }
      end

      # Close admission atomically with respect to admit!, without waiting for
      # admitted callers or calling back into Runtime. Repeated closure is safe.
      def begin_draining
        @mutex.synchronize { @draining = true }
      end

      def wait_until_idle(deadline)
        @mutex.synchronize do
          until @owners.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false if remaining <= 0
            @cond.wait(@mutex, remaining)
          end
          true
        end
      end
    end
  end
end
