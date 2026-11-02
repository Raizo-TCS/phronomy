# frozen_string_literal: true

module Phronomy
  module Agent
    # An opt-in host handle. wait_result yields the ordinary terminal result or
    # the ApprovalWait explicitly detached by the owner of this handle.
    class HostedInvocation
      def initialize(agent, execution_id, task)
        @agent, @execution_id, @task = agent, execution_id, task
        @environment = agent.__execution_environment
      end

      def wait_result(timeout: nil) = @task.wait_result(timeout: timeout)

      # Supports racing normal completion or failure with an approval event.
      def on_complete(&callback)
        @task.on_complete(&callback)
        self
      end

      def detach!(approval_request_id:)
        wait = @agent.persistence.standalone_approval_wait(agent_id: @agent.agent_id, execution_id: @execution_id)
        unless wait && wait.approval_request_id == approval_request_id
          raise Phronomy::AgentBusyError, "No matching standalone approval wait"
        end
        completion = Phronomy::TaskResult.deferred(name: "detach-hosted-approval")
        owner = @environment.registry.agent_execution_owner(@execution_id)
        raise Phronomy::AgentBusyError, "Hosted execution has no local owner" unless owner&.agent.equal?(@agent)
        command = ExecutionCoordinator::DetachHostedWait.new(coordinator: owner.coordinator, wait: wait,
          task: @task, completion: completion)
        accepted = @environment.registry.post(command, completion: completion)
        raise Phronomy::RuntimeShutdownError, "EventLoop rejected hosted detach" unless accepted
        completion.wait_result
      end
    end
  end
end
