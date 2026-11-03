# frozen_string_literal: true

module Phronomy
  module Agent
    # Logical cancellation of a public handle does not release Agent ownership.
    # Only the domain runner acknowledges the end of its accepted operation.
    # @api private
    class OperationResult < Phronomy::Concurrency::PhysicalCompletionTask
      # Published on the EventLoop before the task signals a committed coordination wait.
      attr_accessor :coordination_wait_execution_id

      def initialize(agent:, name:)
        super(name: name)
        @operation_lease = agent.send(:__acquire_operation!)
        @lifetime_mutex = Mutex.new
        @work = 0
        @finished = false
        @released = false
      end

      def finish_operation!
        @lifetime_mutex.synchronize { @finished = true }
        release_if_quiet
      end

      def reserve_approval_detach!(transition, parent: nil)
        @lifetime_mutex.synchronize do
          if @finished || @released || !@work.zero?
            raise Phronomy::AgentBusyError, "Hosted operation is still busy or has finished"
          end
          @operation_lease.reserve_approval_detach!(transition, parent: parent)
        end
      end

      def track(task)
        @lifetime_mutex.synchronize { @work += 1 }
        task.on_physical_complete do
          @lifetime_mutex.synchronize { @work -= 1 }
          release_if_quiet
        end
        task
      end

      def settle(value = nil, error: nil)
        finish_operation!
        error ? fail(error) : complete(value)
      end

      private

      def release_if_quiet
        released = @lifetime_mutex.synchronize do
          next unless @finished && @work.zero? && !@released
          @released = true
          current = @operation_lease
          @operation_lease = nil
          [current]
        end
        return unless released
        released.first&.release
        mark_physical_complete!
      end
    end
  end
end
