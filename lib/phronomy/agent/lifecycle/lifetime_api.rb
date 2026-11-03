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

      # The participant proves which durable retentions are finished history;
      # Agent controls admission, idleness and release of the local owners.
      def __unload_with_peer_execution!(execution_id, reserved_by:)
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError, "Unloading coordinated Agents requires a host thread"
        end
        return false if @_phronomy_runtime_owner_state == :unloaded
        __assert_live_agent!
        peer = persistence.execution_identity(execution_id)
        unless peer.correlation&.slice(*reserved_by.keys) == reserved_by
          raise Phronomy::AgentBusyError, "Execution does not belong to this coordination owner"
        end
        environment = __execution_environment
        environment.ownership.unload_idle_pair(self, peer.agent_id) do |live_peer|
          ids = [agent_id, peer.agent_id].sort
          if ids.any? { |id| environment.existing_registry&.agent_execution_admitted?(id) }
            raise Phronomy::AgentBusyError, "A coordinated Agent has a local execution"
          end
          persistence.transaction do |records, scope|
            unless scope.outermost?
              raise Phronomy::Persistence::TransactionError, "Releasing local owners requires an outermost transaction"
            end
            ids.each { |id| records.executions.assert_idle!(id) }
            unless yield(peer, live_peer, scope)
              raise Phronomy::AgentBusyError, "No matching completed coordination history"
            end
          end
        end
      end

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
