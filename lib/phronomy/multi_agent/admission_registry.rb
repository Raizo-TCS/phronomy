# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Runtime-local admission for one user-facing coordination turn per main Agent.
    # This owns exclusion only; active-agent mutation still belongs to EventLoop.
    class AdmissionRegistry
      def initialize
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @owners = {}
      end

      def admit!(coordinator)
        key = coordinator.object_id
        @mutex.synchronize do
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
