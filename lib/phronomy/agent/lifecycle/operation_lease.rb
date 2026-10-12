# frozen_string_literal: true

module Phronomy
  module Agent
    # C04 capability for accepted work. Never inferred from the current thread.
    # @api private
    class OperationLease
      def initialize(registry, agent, token)
        @registry, @agent, @token = registry, agent, token
        @mutex = Mutex.new
      end

      def release
        ownership = @mutex.synchronize do
          next unless @registry
          current = [@registry, @agent, @token]
          @registry = @agent = @token = nil
          current
        end
        ownership&.first&.release_operation(ownership[1], ownership[2])
      end

      def follow(task)
        if task.respond_to?(:on_physical_complete)
          task.on_physical_complete { release }
        else
          task.on_complete { |_value, _error| release }
        end
        task
      end
    end
  end
end
