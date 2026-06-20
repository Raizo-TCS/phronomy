# frozen_string_literal: true

require "timeout"

module Phronomy
  class Task
    # Backend for Tasks created by {Task#map}.
    #
    # A mapped task's lifecycle is driven entirely by the +on_complete+
    # callback of its source task — it never spawns a thread of its own.
    # +MappedBackend+ transitions the owning task to +:running+ immediately
    # on initialization so that +FSMSession+ treats it as an in-progress
    # async action.  Completion (or failure) is triggered externally via
    # {Task#transition!} from the +on_complete+ callback registered by
    # {Task#map}.
    #
    # +await+ and +join+ block until {#unblock} is called, which {Task#map}
    # arranges by registering a second +on_complete+ callback on the *mapped*
    # task itself after the transform callback has been registered.
    #
    # @api private
    class MappedBackend < Backend
      def initialize(task:, &)
        super
        @done_queue = Queue.new
        task.transition!(:running)
      end

      # Unblocks +await+ / +join+.  Called by {Task#map} after the mapped task
      # reaches a terminal state.
      # @api private
      def unblock(value, error)
        @done_queue.push([value, error])
      end

      # Blocks until the mapped task reaches a terminal state.
      # @return [Object] the mapped value
      # @raise [Exception] if the source task or the map block raised an error
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

      # Returns +false+ — a mapped task has no independent thread to kill.
      # @return [Boolean]
      # @api private
      def alive?
        false
      end

      # No-op — mapped tasks carry no independent thread to cancel.
      # @return [self]
      # @api private
      def cancel!
        self
      end

      # Blocks until the mapped task completes, with an optional timeout.
      # @param limit [Numeric, nil]
      # @return [Object, nil] +nil+ on timeout
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
