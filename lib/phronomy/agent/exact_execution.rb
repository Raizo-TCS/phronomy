# frozen_string_literal: true

module Phronomy
  module Agent
    # Observes a reserved execution using ordinary Agent admission and Recovery.
    # Durable reads/materialization run off EventLoop. Workers never wait for a
    # child lifecycle: the existing EventLoop completion waiter settles Task.
    # @api private
    class ExactExecution
      Wait = Data.define(:coordinator, :agent, :execution_id)
      private_constant :Wait

      def self.start(agent:, execution_id:, input:, config: {})
        new(agent, execution_id, input, config).start
      end

      def initialize(agent, execution_id, input, config)
        @agent, @id, @input, @config = agent, execution_id.to_s.freeze, input, config.freeze
        @runtime = Phronomy::Runtime.instance
        @completion = Phronomy::Task.deferred(name: "exact-execution:#{@id}")
      end

      def start
        preparation = @runtime.offload.submit(on_full: :raise) do
          execution = read_execution
          if execution&.terminal?
            [:terminal, materialize(execution)]
          elsif execution
            unless @runtime.__agent_execution_owner(@id)
              @agent.instance_variable_set(:@_phronomy_coordination_config, @config)
              begin
                RecoveryCoordinator.new(@agent).recover_on_load!
              rescue Phronomy::ConfigurationError => error
                raise Phronomy::ExecutionRehydrationRequiredError,
                  "Execution #{@id} needs current recovery wiring: #{error.message}"
              end
            end
            [:active, nil]
          else
            @config[:cancellation_token]&.raise_if_cancelled!
            [:absent, nil]
          end
        end
        preparation.on_complete do |prepared, error|
          if error
            @completion.fail(error)
          else
            disposition, result = prepared
            case disposition
            when :terminal then @completion.complete(result)
            when :absent
              source = @agent.send(:_start_agent_operation, @input,
                config: @config.merge(phronomy_reserved_execution_id: @id, phronomy_exact_observers: [@completion].freeze),
                mode: :invoke, listener: @agent.send(:_phronomy_event_listener))
              source.on_complete { |_value, failure| reconcile(failure) }
            when :active
              command = Wait.new(coordinator: self, agent: @agent, execution_id: @id)
              posted = @runtime.event_loop.post(Phronomy::Event.new(type: :agent_terminal_ready,
                target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {command: command}))
              @completion.fail(Phronomy::RuntimeShutdownError.new("Exact execution observer rejected")) unless posted
            end
          end
        rescue => failure
          @completion.fail(failure)
        end
        @completion
      rescue => failure
        @completion.fail(failure)
        @completion
      end

      def deliver_on_event_loop(command)
        state = @runtime.event_loop.agent_execution_state(command.execution_id)
        unless state
          # Ownership can be released between the durable read and this command.
          # Reinstall once with the caller's current wiring/cancellation request.
          if !@reinstall_attempted
            @reinstall_attempted = true
            return start
          end
          return reconcile(nil)
        end
        unless state.agent.equal?(command.agent)
          raise Phronomy::Persistence::ConflictError, "Exact execution #{@id} owner mismatch"
        end
        if @config[:cancellation_token]&.cancelled?
          state.invocation&.config&.fetch(:cancellation_token, nil)&.cancel!
        end
        if state.execution.status == :suspended || state.fsm_session_id.nil?
          raise Phronomy::ExecutionRehydrationRequiredError,
            "Execution #{@id} requires approval, factual resolution or current recovery wiring"
        end
        observers = Array(state.invocation.config[:phronomy_exact_observers])
        state.invocation.merge_config!(phronomy_exact_observers: (observers + [@completion]).uniq.freeze)
        waiter = Phronomy::Task.deferred(name: "exact-wait:#{@id}")
        waiter.on_complete { |_result, failure| reconcile(failure) }
        @runtime.event_loop.register_agent_completion_waiter(@id, waiter)
      rescue => failure
        @completion.fail(failure)
      end

      private

      def read_execution
        begin
          execution = @agent.persistence.executions.load(@id)
        rescue Phronomy::Persistence::NotFoundError
          return nil
        end
        unless execution.agent_id == @agent.agent_id
          raise Phronomy::Persistence::ConflictError, "Reserved execution #{@id} belongs to another Agent"
        end
        expected = @config[:phronomy_coordination]
        stored = execution.metadata["coordination"]
        if expected && stored != expected
          actual_identity = stored&.except("handoff_revision")
          expected_identity = expected.except("handoff_revision")
          unless actual_identity == expected_identity
            raise Phronomy::Persistence::ConflictError, "Reserved execution #{@id} coordination mismatch"
          end
        end
        ref = execution.metadata["current_input_ref"]
        if ref && @agent.persistence.contents.fetch_text(ref) != @input
          raise Phronomy::Persistence::ConflictError, "Reserved execution #{@id} input mismatch"
        end
        execution
      end

      def reconcile(failure)
        task = @runtime.offload.submit(on_full: :raise) do
          execution = read_execution
          if execution&.terminal?
            materialize(execution)
          else
            raise(failure || Phronomy::ExecutionRehydrationRequiredError.new(
              "Exact execution #{@id} is unfinished; resume with current wiring"
            ))
          end
        end
        task.on_complete do |result, error|
          error ? @completion.fail(error) : @completion.complete(result)
        end
      rescue => error
        @completion.fail(error)
      end

      def materialize(execution)
        result = @agent.persistence.execution_result(execution.execution_id)
        result.merge(output: result[:result]).freeze
      end
    end
  end
end
