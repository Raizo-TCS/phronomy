# frozen_string_literal: true

require "securerandom"
require "time"
require "digest"

module Phronomy
  module MultiAgent
    # Durable purpose-specific task allocation. Agent owns every Provider/Tool
    # execution; TeamExecution owns queue, assignments and aggregate facts.
    # Scheduling and aggregation must be pure, replay-safe result calculations.
    # @api public
    class TeamCoordinator
      WorkerState = Data.define(:index, :agent_id, :transcript_size, :status) do
        def available? = status == :available
      end
      private_constant :WorkerState

      class << self
        # @api public
        def team_definition(id: nil, version: nil)
          if id || version
            definition_id = id || name
            unless definition_id && !definition_id.to_s.empty? && version && Integer(version).positive?
              raise ArgumentError, "team_definition requires id and positive version"
            end
            @team_definition = {id: (id || name).to_s.freeze, version: Integer(version)}.freeze
          end
          @team_definition || raise(Phronomy::ConfigurationError, "Team must declare team_definition id: ..., version: ...")
        end

        # @api public
        def coordinator_model(value = nil) = value ? @coordinator_model = value : @coordinator_model
        # @api public
        def coordinator_instructions(value = nil) = value ? @coordinator_instructions = value : @coordinator_instructions
        # @api public
        def coordinator_provider(value = nil) = value ? @coordinator_provider = value : @coordinator_provider

        # @api public
        def pool(size:, agent:, on_error: :raise)
          raise ArgumentError, "pool size must be positive" unless Integer(size).positive?
          raise ArgumentError, "on_error must be :raise or :skip" unless %i[raise skip].include?(on_error)
          raise ArgumentError, "pool agent must be an Agent class" unless agent.is_a?(Class) && agent <= Phronomy::Agent::Base
          @pool_size, @worker_agent, @on_error = Integer(size), agent, on_error
        end

        # @api public
        def schedule(&block) = @scheduler = block
        # @api public
        def aggregate(&block) = @aggregator = block

        # @api public
        def new(team_id: SecureRandom.uuid, persistence: nil, metadata: {}, on_event: nil)
          construct(team_id, persistence, metadata, on_event, create: true)
        end

        # @api public
        def create(**options) = new(**options)

        # Hydrates Team facts only; use resume with the exact run ID to continue.
        # @api public
        def load(team_id, persistence:, on_event: nil)
          owner = get(team_id)
          if owner && on_event
            raise Phronomy::ConfigurationError, "Team #{team_id} is already live; listener cannot be rebound"
          end
          construct(team_id, persistence, {}, on_event, create: false)
        end

        # @api public
        def get(team_id) = Phronomy::Runtime.instance.__get_team(team_id, klass: self)

        # @api private
        def _coordinator_model = @coordinator_model
        # @api private
        def _coordinator_instructions = @coordinator_instructions
        # @api private
        def _coordinator_provider = @coordinator_provider
        # @api private
        def _pool_size = @pool_size || 1
        # @api private
        def _worker_agent = @worker_agent
        # @api private
        def _on_error = @on_error || :raise
        # @api private
        def _scheduler = @scheduler
        # @api private
        def _aggregator = @aggregator

        private

        def construct(id, persistence, metadata, listener, create:)
          raise Phronomy::EventLoopReentrancyError, "Team construction cannot block EventLoop" if Phronomy::Runtime.in_event_loop_context?
          key = id.to_s
          raise ArgumentError, "team_id must not be empty" if key.empty?
          store = persistence || Phronomy.configuration.persistence || Phronomy::Persistence::InMemory.new
          runtime = Phronomy::Runtime.instance
          runtime.__team_owner(key, klass: self, create: create, persistence: store) do
            instance = allocate
            instance.send(:initialize, key.freeze, store, metadata, listener, runtime, create: create)
            instance
          end
        end
      end

      # @api public
      attr_reader :team_id, :persistence

      # @api public
      def invoke(team_input, config: {})
        with_admission do
          execution = admit(team_input.to_s, config)
          run(execution.team_execution_id, config)
        end
      end

      # Callback events are observations of committed assignments, never an outbox.
      # @api public
      def stream(team_input, config: {}, &block)
        with_admission do
          execution = admit(team_input.to_s, config)
          run(execution.team_execution_id, config, &block)
        end
      end

      # @api public
      def resume(team_execution_id, config: {})
        with_admission { run(team_execution_id.to_s, config) }
      end

      # No live Agent loading or callbacks are needed for result discovery.
      # @api public
      def result(team_execution_id)
        execution = read_execution(team_execution_id)
        persistence.team_execution_result(execution.team_execution_id)
      end

      # @api public
      def executions(after: nil, limit: 100)
        persistence.list_team_executions(team_id, after: after, limit: limit)
      end

      # Requests cancellation of this run only. Existing Agent cancellation and
      # Recovery settle admitted children; reserved absent children are not started.
      # @api public
      def cancel(team_execution_id)
        assert_caller!
        id = team_execution_id.to_s
        update(id) do |current, _tx|
          next current unless current.active?
          current.with(metadata: current.metadata.merge("cancel_requested" => true))
        end
        token = @tokens_mutex.synchronize { @tokens[id] }
        token&.cancel!
        result(id)
      end

      private

      def initialize(id, store, metadata, listener, runtime, create:)
        @team_id, @persistence, @listener, @runtime = id, store, listener, runtime
        @tokens_mutex, @tokens = Mutex.new, {}
        @coordinator_classes = {}
        definition = self.class.team_definition
        if create
          now = Time.now.utc.iso8601(6)
          intended = TeamRoot.new(team_id: id, team_definition_id: definition.fetch(:id),
            team_definition_version: definition.fetch(:version), team_revision: 0,
            lifecycle_status: "idle", created_at: now, updated_at: now, metadata: metadata)
          begin
            store.transaction { |tx| tx.teams.create(intended) }
          rescue => error
            confirmed = store.teams.load(id)
            raise error unless confirmed.to_h == intended.to_h
          end
        end
        root = store.teams.load(id)
        unless root.team_definition_id == definition.fetch(:id) && root.team_definition_version == definition.fetch(:version)
          raise Phronomy::ConfigurationError, "Team #{id} definition mismatch"
        end
      end

      def assert_caller!
        raise Phronomy::EventLoopReentrancyError, "Team operation cannot block EventLoop" if Phronomy::Runtime.in_event_loop_context?
        unless @runtime.equal?(Phronomy::Runtime.instance)
          raise Phronomy::RuntimeShutdownError, "Team #{team_id} belongs to a previous Runtime"
        end
      end

      def with_admission
        assert_caller!
        @runtime.__admit_multi_agent(self)
        admitted = true
        yield
      ensure
        @runtime.__release_multi_agent(self) if admitted
      end

      def read_execution(id)
        execution = persistence.team_executions.load(id)
        unless execution.team_id == team_id
          raise Phronomy::Persistence::ConflictError, "Team execution #{id} belongs to another Team"
        end
        execution
      end

      def definition_snapshot
        worker = self.class._worker_agent
        raise Phronomy::ConfigurationError, "Team pool agent is missing" unless worker
        {"worker" => worker.agent_definition.transform_keys(&:to_s), "pool_size" => self.class._pool_size,
         "on_error" => self.class._on_error.to_s,
         "coordinator" => self.class.team_definition.transform_keys(&:to_s)}
      end

      def admit(input, config = {})
        definition = definition_snapshot
        id = SecureRandom.uuid
        now = Time.now.utc.iso8601(6)
        intended = nil
        begin
          persistence.transaction do |tx|
            root = tx.teams.load(team_id)
            raise Phronomy::AgentBusyError, "Team #{team_id} has an active run; use resume" unless tx.team_executions.list_active(team_id).empty?
            intended = TeamExecution.new(team_execution_id: id, team_id: team_id,
              execution_revision: 0, status: "active", phase: "coordinator", input_ref: tx.contents.put_text(input),
              coordinator: {"agent_id" => SecureRandom.uuid, "execution_id" => SecureRandom.uuid, "state" => "reserved"},
              workers: Array.new(self.class._pool_size) { |i| {"index" => i, "agent_id" => SecureRandom.uuid, "transcript_size" => 0} },
              tasks: [], assignments: [], result_ref: nil, error_ref: nil, created_at: now, updated_at: now,
              metadata: {"definition" => definition, "operations" => {}, "cancel_requested" => false,
                         "durable_context_ref" => config.key?(:durable_context) ? tx.contents.put_json(config.fetch(:durable_context)) : nil})
            tx.team_executions.create_active(intended)
            tx.teams.save(team_id, expected_revision: root.team_revision, root: root.with(lifecycle_status: "active"))
          end
        rescue => error
          raise error unless intended
          begin
            confirmed = read_execution(id)
          rescue Phronomy::Persistence::NotFoundError
            raise error
          end
          raise error unless confirmed.to_h == intended.to_h
        end
        intended
      end

      # The body only derives immutable facts. Failed readback propagates; it is
      # never interpreted as absence. A known CAS loser may rebase the same fact.
      def update(id)
        attempts = 0
        begin
          intended = nil
          persistence.transaction do |tx|
            current = tx.team_executions.load(id)
            raise Phronomy::Persistence::ConflictError, "Team execution owner mismatch" unless current.team_id == team_id
            intended = yield(current, tx)
            next if intended.equal?(current)
            tx.team_executions.save(id, expected_revision: current.execution_revision, execution: intended)
            if intended.terminal? && current.active?
              root = tx.teams.load(team_id)
              tx.teams.save(team_id, expected_revision: root.team_revision, root: root.with(lifecycle_status: "idle"))
            end
          end
          intended
        rescue => error
          confirmed = read_execution(id)
          return confirmed if intended && confirmed.to_h == intended.to_h
          if error.is_a?(Phronomy::Persistence::ConflictError) && (attempts += 1) < 8
            retry
          end
          raise error
        end
      end

      def run(id, config)
        current = read_execution(id)
        return terminal_value(current) if current.terminal?
        unless current.metadata.fetch("definition") == definition_snapshot
          raise Phronomy::ConfigurationError, "Team execution #{id} pool/definition mismatch"
        end
        token = Phronomy::Concurrency::CancellationToken.new
        @tokens_mutex.synchronize { @tokens[id] = token }
        external = config[:cancellation_token]
        callback = proc { @runtime.offload.submit(on_full: :raise) { cancel(id) } }
        external&.on_cancel(&callback)
        token.cancel! if current.metadata["cancel_requested"]
        begin
          loop do
            current = read_execution(id)
            return terminal_value(current) if current.terminal?
            token.cancel! if current.metadata["cancel_requested"]
            if current.phase == "coordinator"
              outcome = run_child(current, current.coordinator, coordinator_class(id),
                persistence.contents.fetch_text(current.input_ref), "coordinator", config, token)
              update(id) do |fresh, _tx|
                fresh.with(phase: "workers", coordinator: fresh.coordinator.merge(
                  "state" => outcome[:status].to_s, "result_ref" => outcome[:result_ref], "error_ref" => outcome[:error_ref]
                ))
              end
              return terminal_value(finish_error(id, outcome[:error])) if outcome[:error] && !token.cancelled?
              next
            end
            unfinished = current.assignments.find { |entry| entry.fetch("state") == "reserved" }
            if unfinished
              worker = current.workers.fetch(unfinished.fetch("worker"))
              task = current.tasks.find { |item| item.fetch("id") == unfinished.fetch("task_id") }
              outcome = run_child(current, worker.merge("execution_id" => unfinished.fetch("execution_id")),
                self.class._worker_agent, task.fetch("description"), unfinished.fetch("task_id"), config, token)
              saved = record_assignment(id, unfinished, outcome)
              entry = assignment_values(saved).find { |item| item.fetch(:task).fetch(:id) == task.fetch("id") }
              yield entry.merge(type: outcome[:error] ? :task_failed : :task_completed) if block_given?
              if outcome[:error] && current.metadata.fetch("definition").fetch("on_error") == "raise" && !token.cancelled?
                return terminal_value(finish_error(id, outcome[:error]))
              end
              next
            end
            if token.cancelled?
              return terminal_value(finish_error(id, {"class" => "Phronomy::CancellationError", "message" => "Team run cancelled"}, status: "cancelled"))
            end
            task = current.tasks.find { |item| current.assignments.none? { |a| a.fetch("task_id") == item.fetch("id") } }
            if task
              reserve_assignment(current, task)
              next
            end
            values = assignment_values(current)
            aggregate = self.class._aggregator
            begin
              output = Phronomy::Agent::RecoverySupport.canonical_copy(aggregate ? aggregate.call(values) : values)
              Phronomy::CanonicalJSON.dump(output)
            rescue => error
              return terminal_value(finish_error(id, Phronomy::Agent::RecoverySupport.resolution_failure(error)))
            end
            # Aggregate may be replayed only until the canonical outcome commits.
            completed = update(id) do |fresh, tx|
              next fresh if fresh.terminal? || fresh.metadata["cancel_requested"]
              fresh.with(status: "completed", phase: "completed", result_ref: tx.contents.put_json(output))
            end
            next if completed.active?
            return terminal_value(completed)
          end
        rescue Phronomy::CancellationError
          # An absent reserved child is not started just to cancel it. Keep its
          # identity in the terminal Team record for discovery.
          terminal_value(finish_error(id, {"class" => "Phronomy::CancellationError", "message" => "Team run cancelled"}, status: "cancelled"))
        ensure
          external&.send(:unregister_cancel_callback, callback)
          @tokens_mutex.synchronize { @tokens.delete(id) }
        end
      end

      def run_child(current, slot, klass, input, purpose, config, token)
        id = slot.fetch("agent_id")
        child = klass.get(id)
        unless child
          begin
            persistence.agents.load(id)
            present = true
          rescue Phronomy::Persistence::NotFoundError
            present = false
          end
          token.raise_if_cancelled! unless present
          child = present ? klass.load(id, persistence: persistence, on_event: @listener) : klass.create(agent_id: id, persistence: persistence, on_event: @listener)
        end
        unless child.persistence.equal?(persistence)
          raise Phronomy::ConfigurationError, "Team child #{id} Persistence mismatch"
        end
        child_config = config.merge(cancellation_token: token,
          phronomy_coordination: {"kind" => "team", "team_id" => team_id,
                                  "team_execution_id" => current.team_execution_id, "slot" => purpose})
        if (context_ref = current.metadata["durable_context_ref"])
          child_config = child_config.merge(durable_context: persistence.contents.fetch_json(context_ref))
        end
        Phronomy::Agent::ExactExecution.start(agent: child, execution_id: slot.fetch("execution_id"), input: input, config: child_config).wait_result
      end

      def reserve_assignment(current, task)
        available = current.workers.map { |w| WorkerState.new(index: w.fetch("index"), agent_id: w.fetch("agent_id"), transcript_size: w.fetch("transcript_size"), status: :available) }.freeze
        worker = self.class._scheduler ? self.class._scheduler.call(available) : available.min_by(&:transcript_size)
        raise Phronomy::ConfigurationError, "Scheduler must select an available worker slot" unless available.include?(worker)
        reserved = {"task_id" => task.fetch("id"), "worker" => worker.index,
                    "execution_id" => SecureRandom.uuid, "state" => "reserved", "result_ref" => nil, "error_ref" => nil}
        update(current.team_execution_id) do |fresh, _tx|
          next fresh if fresh.metadata["cancel_requested"] || fresh.assignments.any? { |entry| entry.fetch("task_id") == task.fetch("id") }
          fresh.with(assignments: fresh.assignments + [reserved])
        end
      end

      def record_assignment(id, assigned, outcome)
        update(id) do |fresh, tx|
          entries = fresh.assignments.map do |entry|
            next entry unless entry.fetch("task_id") == assigned.fetch("task_id")
            next entry unless entry.fetch("state") == "reserved"
            raise Phronomy::Persistence::ConflictError, "Assignment execution changed" unless entry.fetch("execution_id") == outcome.fetch(:execution_id)
            entry.merge("state" => outcome.fetch(:status).to_s,
              "result_ref" => outcome[:result_ref], "error_ref" => outcome[:error_ref])
          end
          workers = fresh.workers.map do |worker|
            next worker unless worker.fetch("index") == assigned.fetch("worker")
            root = tx.agents.load(worker.fetch("agent_id"))
            worker.merge("transcript_size" => root.journal_position)
          end
          fresh.with(assignments: entries, workers: workers)
        end
      end

      def assignment_values(execution)
        execution.assignments.map do |entry|
          task = execution.tasks.find { |item| item.fetch("id") == entry.fetch("task_id") }
          {task: task.transform_keys(&:to_sym), worker: entry.fetch("worker"),
           result: entry["result_ref"] && persistence.contents.fetch_text(entry.fetch("result_ref")),
           error: entry["error_ref"] && persistence.contents.fetch_json(entry.fetch("error_ref"))}.freeze
        end.freeze
      end

      def finish_error(id, error, status: "failed")
        update(id) do |fresh, tx|
          next fresh if fresh.terminal?
          fresh.with(status: status, phase: status, error_ref: tx.contents.put_json(error))
        end
      end

      def terminal_value(execution)
        raise Phronomy::CancellationError, "Team run #{execution.team_execution_id} cancelled" if execution.status == "cancelled"
        raise Phronomy::Agent::RecoverySupport.error_from_failure(persistence.contents.fetch_json(execution.error_ref)) if execution.error_ref
        persistence.contents.fetch_json(execution.result_ref)
      end

      def coordinator_class(id)
        @coordinator_classes[id] ||= begin
          definition = self.class.team_definition
          model = self.class._coordinator_model
          provider = self.class._coordinator_provider
          instructions = self.class._coordinator_instructions
          enqueue = build_operation_tool(id, :enqueue_task)
          finalize = build_operation_tool(id, :finalize)
          Class.new(Phronomy::Agent::Base) do
            agent_definition id: "team:#{definition.fetch(:id)}:coordinator", version: definition.fetch(:version)
            model(model) if model
            provider(provider) if provider
            instructions(instructions) if instructions
            tools(enqueue => nil, finalize => nil)
            define_method(:__framework_tool_replayable?) { |name| %w[enqueue_task finalize].include?(name) }
          end
        end
      end

      def build_operation_tool(run_id, operation)
        team = self
        Class.new(Phronomy::Agent::Context::Capability::Base) do
          def self.__framework_owned_operation? = true
          tool_name operation.to_s
          description((operation == :enqueue_task) ? "Add a task to the worker queue." : "Finish task generation.")
          execution_mode :cooperative
          if operation == :enqueue_task
            param :description, type: :string, desc: "Worker task"
            param :metadata, type: :string, desc: "Optional metadata", required: false
          else
            param :summary, type: :string, desc: "Task summary", required: false
          end
          define_method(:call_async) do |args, cancellation_token: nil, config: {}|
            validated, schema_error = send(:validate_and_coerce, args)
            raise Phronomy::ToolError, schema_error if schema_error
            execute_async(**validated, cancellation_token: cancellation_token, config: config)
          rescue => error
            Phronomy::Task.deferred(name: "team-operation-failed").tap { |task| task.fail(error) }
          end
          define_method(:execute_async) do |config: {}, cancellation_token: nil, **arguments|
            key = config.fetch(:phronomy_tool_invocation_id)
            Phronomy::Runtime.instance.offload.submit(on_full: :raise) do
              team.send(:apply_operation, run_id, key, operation, arguments)
            rescue Phronomy::CancellationError
              raise
            rescue => error
              raise Phronomy::ExecutionRehydrationRequiredError, "Team operation #{key} needs reconciliation: #{error.message}"
            end
          end
          private :execute_async
        end
      end

      def apply_operation(run_id, key, operation, arguments)
        argument_values = Phronomy::Agent::RecoverySupport.canonical_copy(arguments)
        current = update(run_id) do |fresh, tx|
          operations = fresh.metadata.fetch("operations")
          if (prior = operations[key])
            unless prior.fetch("operation") == operation.to_s && prior.fetch("arguments") == argument_values
              raise Phronomy::Persistence::ConflictError, "Team operation #{key} identity mismatch"
            end
            next fresh
          end
          raise Phronomy::CancellationError, "Team run cancelled" if fresh.metadata["cancel_requested"]
          raise Phronomy::Persistence::ConflictError, "Team task generation is closed" unless fresh.active? && fresh.phase == "coordinator"
          coordinator = tx.executions.load(fresh.coordinator.fetch("execution_id"))
          unless coordinator.agent_id == fresh.coordinator.fetch("agent_id")
            raise Phronomy::Persistence::ConflictError, "Team coordinator owner mismatch"
          end
          batch = Array(coordinator.metadata[Phronomy::Agent::RecoverySupport::TOOL_BATCH_METADATA_KEY])
          requested = batch.find { |entry| entry.fetch("tool_invocation_id") == key }
          unless requested && requested.fetch("status") == "authorized" && requested.fetch("tool_name") == operation.to_s && requested.fetch("arguments").compact == argument_values
            raise Phronomy::Persistence::ConflictError, "Team operation #{key} is not the authorized call"
          end
          # All calls passed the Agent authorization barrier. Commit this finite
          # batch in Provider order, so finalize cannot overtake queued tasks.
          tasks = fresh.tasks.dup
          operations = operations.dup
          metadata = fresh.metadata.dup
          batch.each do |entry|
            entry_id = entry.fetch("tool_invocation_id")
            next if operations.key?(entry_id) || entry.fetch("status") != "authorized"
            name = entry.fetch("tool_name")
            next unless %w[enqueue_task finalize].include?(name)
            values = entry.fetch("arguments").compact
            if name == "enqueue_task"
              raise Phronomy::ConfigurationError, "Cannot enqueue after finalize" if metadata["finalized"]
              task = {"id" => Digest::SHA256.hexdigest(entry_id)[0, 32], "description" => values.fetch("description"), "metadata" => values["metadata"]}
              tasks << task
              output = "Task ##{tasks.length} enqueued: #{task.fetch("description")}"
            else
              output = "Finalized. #{tasks.size} task(s) enqueued. #{values["summary"]}".strip
              metadata["finalized"] = true
            end
            operations[entry_id] = {"operation" => name, "arguments" => values, "result" => output}
          end
          metadata["operations"] = operations
          fresh.with(tasks: tasks, metadata: metadata)
        end
        current.metadata.fetch("operations").fetch(key).fetch("result")
      end
    end
  end
end
