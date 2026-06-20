# frozen_string_literal: true

require "timeout"

module Phronomy
  class Task
    # Backend for externally-completed Tasks.
    #
    # DeferredBackend never starts a thread.  The owner transitions it to a
    # terminal state by calling Task#transition! and then #unblock.
    # @api private
    class DeferredBackend < Backend
      def initialize(task:, &)
        super
        @done_queue = Queue.new
        task.transition!(:running)
      end

      # Unblocks await/join after the task reaches a terminal state.
      # @api private
      def unblock(value, error)
        @done_queue.push([value, error])
      end

      # Blocks until externally completed.
      # @api private
      def wait_result
        scheduler = Thread.current.thread_variable_get(Task::SCHEDULER_KEY)
        in_managed_fiber = !Fiber.respond_to?(:main) || Fiber.current != Fiber.main
        if scheduler && in_managed_fiber && !@task.done?
          scheduler.track_blocking_await
          waiting_fiber = Fiber.current
          @task.on_complete do |_value, _error|
            scheduler.complete_blocking_await
            scheduler.enqueue_fiber(-> { waiting_fiber.resume })
          end
          Fiber.yield(:cooperative_suspend)
        end

        value, error = @done_queue.pop
        raise error if error

        value
      end

      # Deferred tasks have no execution thread of their own.
      # @api private
      def alive?
        !@task.done?
      end

      # Marks the task cancelled without interrupting external work.
      # @api private
      def cancel!
        self
      end

      # Blocks until externally completed, with optional timeout.
      # @api private
      def join(limit = nil)
        if limit.nil?
          wait_result
        else
          begin
            Timeout.timeout(limit) { wait_result }
          rescue Timeout::Error
            nil
          end
        end
      end
    end
  end
end
