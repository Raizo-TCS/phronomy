# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent-owned two-phase release. The worker only checks durable facts; the
    # EventLoop completes the exact process-local reservation after physical I/O.
    # @api private
    class UnloadTransition
      Command = Data.define(:coordinator, :phase)
      private_constant :Command

      attr_reader :result

      def initialize(agent:, environment:, ownership:)
        @agent, @environment, @ownership = agent, environment, ownership
        @result = Phronomy::TaskResult.deferred(name: "agent-unload:#{agent.agent_id}")
        @mutex = Mutex.new
        @finished = false
      end

      def start
        post(:check)
        @result
      end

      def deliver_on_event_loop(command)
        if command.phase == :check
          if @environment.existing_registry&.agent_execution_admitted?(@agent.agent_id)
            raise Phronomy::AgentBusyError, "Agent #{@agent.agent_id.inspect} has a nonterminal execution"
          end
          agent_id, persistence = @agent.agent_id, @agent.persistence
          task = @environment.submit(on_full: :raise) do
            persistence.transaction do |tx|
              tx.executions.assert_idle!(agent_id)
              tx.guard_agent!(agent_id)
              unless tx.retentions.list(agent_id).empty?
                raise Phronomy::AgentBusyError, "Agent #{agent_id.inspect} is retained by durable coordination"
              end
            end
          end
          task.on_complete do |_value, error|
            @read_error = error
            task.on_physical_complete { post(:apply) }
          end
        else
          finish(@read_error)
        end
      rescue => error
        finish(error)
      end

      private

      def post(phase)
        accepted = @environment.registry.post(Command.new(coordinator: self, phase: phase), completion: @result)
        finish(Phronomy::RuntimeShutdownError.new("EventLoop rejected Agent unload #{phase}")) unless accepted
      rescue => error
        finish(error)
      end

      def finish(error)
        first = @mutex.synchronize do
          next false if @finished
          @finished = true
        end
        return unless first

        begin
          @ownership.finish_unload(@agent, self, success: error.nil?)
        rescue => ownership_error
          error ||= ownership_error
        end
        @agent = @environment = @ownership = nil
        error ? @result.fail(error) : @result.complete(true)
      end
    end
  end
end
