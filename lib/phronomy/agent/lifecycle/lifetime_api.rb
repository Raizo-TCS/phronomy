# frozen_string_literal: true

module Phronomy
  module Agent
    # Public admission boundaries. The explicit operation capability belongs to
    # C04, including queued work and domain completion after logical cancellation.
    # @api private
    module LifetimeApi
      # Releases only the Runtime incarnation; durable state and Store stay intact.
      # @return [TaskResult<Boolean>]
      # @api public
      def unload_async
        return Phronomy::TaskResult.completed(false) if @_phronomy_runtime_owner_state == :unloaded

        __assert_agent_accessible!
        transition, start = __execution_environment.ownership.reserve_unload(self)
        start ? transition.start : transition.result
      rescue => error
        Phronomy::TaskResult.failed(error)
      end

      # A timeout stops this wait, never the accepted release.
      # @return [Boolean]
      # @api public
      def unload!(timeout: nil)
        _check_event_loop_reentrancy(:unload!, :unload_async)
        unload_async.wait_result(timeout: timeout)
      end

      private

      def __with_operation(async: false, read_only: false)
        lease = __acquire_operation!(read_only: read_only)
        followed = false
        value = yield
        if async && lease
          lease.follow(value)
          followed = true
        end
        value
      rescue Phronomy::AgentUnloadedError, Phronomy::AgentBusyError, Phronomy::RuntimeShutdownError => error
        raise unless async
        Phronomy::TaskResult.failed(error)
      ensure
        lease&.release unless followed
      end

      # Accepted C04 commands carry their admission/operation capability. Their
      # continuations read the snapshot without entering the public admission gate.
      def __root_for_operation
        __assert_agent_accessible!
        @root
      end

      def __acquire_operation!(read_only: false)
        __assert_agent_accessible!
        return nil if @_phronomy_runtime_owner_state == :constructing

        __execution_environment.ownership.acquire_operation(self, read_only: read_only)
      end

      def __mark_unloaded!
        @_phronomy_runtime_owner_state = :unloaded
        @root = nil
        @_phronomy_journal_records = [].freeze
        @_phronomy_event_listener = nil
        @_phronomy_execution_wiring = {}.freeze
        @execution_coordinator = nil
        @tool_approval_policy = @before_llm_input = nil
        @_instance_input_filters = @_instance_output_filters = nil
        @_instance_tool_result_filters = @_scoped_tool_result_filters = nil
        @initial_retention = nil
      end
    end
  end
end
