# frozen_string_literal: true

module Phronomy
  module Agent
    # An opt-in host handle. wait_result yields the ordinary terminal result or
    # an ApprovalWait when the hosted operation itself is detached.
    class HostedInvocation
      def initialize(agent, execution_id, task, resumed_from: nil, &child_approval_wait)
        @agent, @execution_id, @task = agent, execution_id, task
        @environment = agent.__execution_environment
        @resumed_from = resumed_from
        @child_approval_wait = child_approval_wait
      end

      def wait_result(timeout: nil) = @task.wait_result(timeout: timeout)

      # Supports racing normal completion or failure with an approval event.
      def on_complete(&callback)
        @task.on_complete(&callback)
        self
      end

      def detach!(approval_request_id:, execution_id: @resumed_from&.execution_id || @execution_id)
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError, "detach! requires a host thread"
        end
        child = execution_id != @execution_id
        wait = if @resumed_from
          if execution_id == @resumed_from.execution_id && approval_request_id != @resumed_from.approval_request_id
            @child_approval_wait.call(execution_id, approval_request_id)
          end
        elsif child
          matching_child_wait(execution_id, approval_request_id)
        else
          @agent.persistence.standalone_approval_wait(agent_id: @agent.agent_id, execution_id: @execution_id)
        end
        unless wait && wait.approval_request_id == approval_request_id
          raise Phronomy::AgentBusyError, "No matching hosted approval wait"
        end
        owner = @environment.registry.agent_execution_owner(execution_id)
        unless owner && (child ? owner.agent.persistence.equal?(@agent.persistence) : owner.agent.equal?(@agent))
          raise Phronomy::AgentBusyError, "Hosted execution has no matching local owner"
        end
        completion = owner.coordinator.request_hosted_detach(wait,
          task: (child && !@resumed_from) ? nil : @task, parent: child ? @agent : nil)
        completion.wait_result
      end

      private

      def matching_child_wait(execution_id, approval_request_id)
        settled = @task.done?
        wait = @child_approval_wait&.call(execution_id, approval_request_id)
        return unless wait

        # The child's event can precede the parent's committed coordination
        # wait. Physical completion and that exact outcome authorize release.
        @task.join
        unless @task.coordination_wait_execution_id == @execution_id && @task.physical_complete?
          @task.wait_result # Propagate a parent failure other than a committed wait.
          raise Phronomy::AgentBusyError, "Hosted parent did not reach its coordination wait"
        end
        wait if settled || @child_approval_wait.call(execution_id, approval_request_id) == wait
      end
    end
  end
end
