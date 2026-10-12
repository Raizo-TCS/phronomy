# frozen_string_literal: true

module Phronomy
  module Agent
    # Owns the Agents materialized within one application operation. A scope is
    # Runtime-bound, process-local, and must not be persisted as Workflow state.
    # @api public
    class Scope
      # @api private
      def self.open
        raise ArgumentError, "open_scope requires a block" unless block_given?
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError, "Agent.open_scope cannot block EventLoop"
        end

        scope = new(environment: ExecutionEnvironment.current)
        result = nil
        begin
          result = yield(scope)
          result = result.wait_result if result.is_a?(Phronomy::TaskResult)
        rescue Exception => primary # standard:disable Lint/RescueException
          raise
        ensure
          failures = scope.send(:__close)
          if primary
            failures.each do |failure|
              error = failure.fetch(:error)
              Phronomy::RuntimeSettings.current.logger&.warn(
                "[Agent scope] cleanup failed agent_id=#{failure.fetch(:agent_id).inspect}: #{error.class}: #{error.message}"
              )
            rescue
              nil
            end
          elsif failures.any?
            raise ScopeCleanupError.new(failures: failures, result: result)
          end
        end
        result
      end
      private_class_method :open

      def initialize(environment:)
        @environment = environment
        @ownership = environment.ownership
        @owner_token = Object.new.freeze
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @state = :open
        @receipts = {}
        @agents = {}
      end
      private_class_method :new

      # @return [Agent::Base]
      # @api public
      def create(agent_class, **options, &listener)
        check_blocking!
        materialize(:create, agent_class, options, listener, async: false)
      end

      # @return [TaskResult<Agent::Base>]
      # @api public
      def create_async(agent_class, **options, &listener)
        materialize(:create, agent_class, options, listener, async: true)
      rescue => error
        Phronomy::TaskResult.failed(error)
      end

      # Repeated load in this scope returns the same live owner. Supplying a new
      # listener or different Store for an already live instance is rejected.
      # @return [Agent::Base]
      # @api public
      def load(agent_class, agent_id, persistence:, **options, &listener)
        check_blocking!
        materialize(:load, agent_class, options.merge(agent_id: agent_id, persistence: persistence), listener, async: false)
      end

      # @return [TaskResult<Agent::Base>]
      # @api public
      def load_async(agent_class, agent_id, persistence:, **options, &listener)
        materialize(:load, agent_class, options.merge(agent_id: agent_id, persistence: persistence), listener, async: true)
      rescue => error
        Phronomy::TaskResult.failed(error)
      end

      # @api private
      def __close
        agents = @mutex.synchronize do
          @state = :closing
          @condition.wait(@mutex) until @receipts.empty?
          @agents.values.dup
        end
        failures = []
        agents.each do |agent|
          agent.unload!
        rescue => error
          failures << {agent_id: agent.agent_id, error: error}.freeze
        end
        @mutex.synchronize do
          @agents.clear
          @environment = @ownership = @owner_token = nil
          @state = :closed
        end
        failures.freeze
      end
      private :__close

      private

      def check_blocking!
        return unless Phronomy::WaitPolicy.blocking_forbidden?

        raise Phronomy::EventLoopReentrancyError, "Agent scope materialization cannot block EventLoop; use create_async/load_async"
      end

      def materialize(kind, agent_class, options, listener, async:)
        unless agent_class.is_a?(Class) && agent_class <= Base
          raise ArgumentError, "agent_class must be an Agent::Base subclass"
        end
        if options[:on_event] && listener
          raise ArgumentError, "Provide either on_event: or a block, not both"
        end
        if kind == :load && !options[:persistence]
          raise ArgumentError, "persistence is required"
        end
        key = (options[:agent_id] || (SecureRandom.uuid if kind == :create)).to_s.dup.freeze
        raise ArgumentError, "agent_id must not be empty" if key.empty?
        options = options.merge(agent_id: key)
        receipt = Object.new.freeze
        @mutex.synchronize do
          raise Phronomy::Error, "Agent scope is #{@state}" unless @state == :open
          @receipts[receipt] = key
        end
        operation = -> { acquire(kind, agent_class, key, options, listener) }
        if async
          begin
            task = @environment.submit(on_full: :raise, &operation)
            task.on_physical_complete { finish_receipt(receipt) }
            task
          rescue
            finish_receipt(receipt)
            raise
          end
        else
          begin
            operation.call
          ensure
            finish_receipt(receipt)
          end
        end
      end

      def acquire(kind, agent_class, key, options, listener)
        materialized = false
        agent = @ownership.public_send(kind, key, expected_class: agent_class, scope_owner: @owner_token) do |environment|
          materialized = true
          instance = agent_class.send(:__construct_owned_agent, environment, key,
            **options, load_existing: kind == :load, &listener)
          RecoveryCoordinator.new(instance).recover_on_load! if kind == :load
          instance
        end
        # Register before any result or post-materialization check reaches the
        # caller, even when scope closure began while the worker was running.
        @mutex.synchronize { @agents[agent.object_id] = agent }
        if kind == :load
          unless agent.persistence.equal?(options[:persistence])
            raise Phronomy::ConfigurationError, "Agent #{key.inspect} is already live with a different Persistence instance"
          end
          if !materialized && (options[:on_event] || listener)
            raise Phronomy::ConfigurationError, "Agent #{key.inspect} is already live; load cannot re-bind on_event"
          end
        end
        agent
      rescue Phronomy::Persistence::ConflictError => error
        raise unless kind == :create
        raise Phronomy::AgentAlreadyExistsError, "Agent #{key.inspect} already exists durably: #{error.message}"
      rescue => error
        # A fail-closed construction remains reserved in C04. Do not purge or
        # release that reservation just because no instance reached this scope.
        report_materialization_error(key, error)
        raise
      end

      def finish_receipt(receipt)
        @mutex.synchronize do
          @receipts.delete(receipt)
          @condition.broadcast
        end
      end

      def report_materialization_error(key, error)
        Phronomy::RuntimeSettings.current.logger&.warn("[Agent scope] materialization failed agent_id=#{key.inspect}: #{error.class}: #{error.message}")
      rescue
        nil
      end
    end
  end
end
